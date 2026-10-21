{-# LANGUAGE OverloadedStrings #-}

-- | The imperative shell: fetch, cache, serve.
--
-- The one idea worth stating. A background loop owns freshness and publishes
-- whole immutable 'Snapshot's into a 'TVar'; HTTP handlers only ever read that
-- TVar. So a request never waits on IMD, never fails because IMD failed, and
-- always sees a consistent set of layers and cells. Slow network work and fast
-- page loads are simply decoupled, rather than raced.
module Main (main) where

import Codec.Picture (convertRGB8, decodeImage)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.Aeson (Value, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Time
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Simple
import Network.HTTP.Types (status404)
import Network.TLS qualified as TLS
import RTW.Cells
import RTW.Config
import RTW.Decode
import RTW.Page (page)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Info (os)
import System.Process (callProcess)
import Web.Scotty

-- | One radar's contribution to the current picture. Carrying the whole
-- 'Product' means the page can draw the scan boundary too -- without it,
-- "no echo" and "outside coverage" look identical on the map.
data Layer = Layer
  { lyProduct :: !Product
  , lyBounds :: !Bounds
  , lyPng :: !BL.ByteString
  }

-- | Everything the page needs, as one value that is swapped atomically.
data Snapshot = Snapshot
  { snVersion :: !Int
  , snLayers :: ![Layer]
  , snCells :: ![Cell]
  , snNote :: !Text
  }

initial :: Snapshot
initial = Snapshot 0 [] [] "fetching the first scan…"

-- Fetch + decode -----------------------------------------------------------

-- | mausam.imd.gov.in predates RFC 7627, and tls >= 2 requires Extended Main
-- Secret by default, so the handshake is refused outright. Browsers and curl
-- are lenient about it. We relax that single requirement and nothing else --
-- certificate validation stays on.
imdManager :: IO Manager
imdManager = newManager (mkManagerSettings relaxed Nothing)
  where
    relaxed =
      TLSSettingsSimple
        { settingDisableCertificateValidation = False
        , settingDisableSession = False
        , settingUseServerName = False
        , settingClientSupported =
            TLS.defaultSupported {TLS.supportedExtendedMainSecret = TLS.AllowEMS}
        }

-- | HttpException's Show dumps the entire request record; the cause is last.
brief :: SomeException -> Text
brief = T.strip . T.takeEnd 120 . T.pack . show

grab :: Manager -> Product -> IO (Either Text (Layer, [Cell]))
grab mgr p = do
  attempt <- try @SomeException $ do
    req <- parseRequest (stillUrl p)
    resp <-
      httpBS
        . setRequestManager mgr
        . setRequestHeader "User-Agent" ["realtime-weather/0.1"]
        $ req
    pure (getResponseBody resp)
  pure $ case attempt of
    Left e -> Left (brief e)
    Right bytes -> case decodeImage bytes of
      Left err -> Left (T.pack err)
      Right dyn ->
        let grid = decode p (convertRGB8 dyn)
         in Right
              ( Layer p (bounds p) (overlayPng grid)
              , findCells 30 p grid
              )

rebuild :: Manager -> Int -> IO Snapshot
rebuild mgr v = do
  results <- mapM (\p -> (,) p <$> grab mgr p) products
  now <- getCurrentTime
  let good = [x | (_, Right x) <- results]
      bad = [pLabel p <> ": " <> e | (p, Left e) <- results]
      cells = fuse 12 (concatMap snd good)
      note =
        T.intercalate
          "<br>"
          ( [ T.pack (show (length good))
                <> " radars · "
                <> T.pack (show (length cells))
                <> " cells · "
                <> istStamp now
            ]
              <> bad
          )
  pure (Snapshot v (map fst good) cells note)

istStamp :: UTCTime -> Text
istStamp t =
  T.pack (formatTime defaultTimeLocale "%d %b %H:%M IST" (utcToLocalTime ist t))
  where
    ist = TimeZone 330 False "IST"

-- | Owns freshness so that no HTTP handler ever has to.
refresher :: Manager -> Int -> TVar Snapshot -> IO ()
refresher mgr secs var = go 1
  where
    go v = do
      snap <- rebuild mgr v
      atomically (writeTVar var snap)
      putStrLn ("  refreshed v" <> show v <> " — " <> T.unpack (T.replace "<br>" " | " (snNote snap)))
      threadDelay (secs * 1000000)
      go (v + 1)

-- Serve --------------------------------------------------------------------

stateJson :: Snapshot -> Value
stateJson s =
  object
    [ "version" .= snVersion s
    , "note" .= snNote s
    , "cells" .= snCells s
    , "layers"
        .= [ object
               [ "code" .= pCode p
               , "label" .= pLabel p
               , "bounds" .= [bSouth b, bWest b, bNorth b, bEast b]
               , "site" .= [pLat p, pLon p]
               , "rangeKm" .= pRangeKm p
               , "url" .= ("/layer/" <> pCode p <> ".png?v=" <> T.pack (show (snVersion s)))
               ]
           | l <- snLayers s
           , let b = lyBounds l
           , let p = lyProduct l
           ]
    ]

openBrowser :: String -> IO ()
openBrowser url = void . try @SomeException $ case os of
  "darwin" -> callProcess "open" [url]
  "mingw32" -> callProcess "cmd" ["/c", "start", url]
  _ -> callProcess "xdg-open" [url]

basemapName :: Settings -> String
basemapName s
  | Just st <- sMapboxStyle s, Just _ <- sMapboxToken s = "Mapbox " <> T.unpack st
  | Just _ <- sCartoKey s = "CARTO Voyager"
  | otherwise = "Esri (no key configured)"

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  settings <- loadSettings
  mgr <- imdManager
  var <- newTVarIO initial
  let url = "http://localhost:" <> show (sPort settings)

  putStrLn "Real Time Weather"
  putStrLn ("  basemap  " <> basemapName settings)
  putStrLn ("  refresh  every " <> show (sRefreshSec settings) <> "s")
  putStrLn ("  serving  " <> url)

  void (forkIO (refresher mgr (sRefreshSec settings) var))
  void (forkIO (threadDelay 500000 >> openBrowser url))

  scotty (sPort settings) $ do
    get "/" $ do
      setHeader "Content-Type" "text/html; charset=utf-8"
      html (TL.fromStrict (page settings))

    get "/api/state" $ do
      liftIO (readTVarIO var) >>= json . stateJson

    get "/layer/:code" $ do
      wanted <- pathParam "code"
      snap <- liftIO (readTVarIO var)
      case lookup (T.takeWhile (/= '.') wanted) [(pCode (lyProduct l), lyPng l) | l <- snLayers snap] of
        Just png -> do
          setHeader "Content-Type" "image/png"
          setHeader "Cache-Control" "public, max-age=300"
          raw png
        Nothing -> status status404 >> text "no such layer"
