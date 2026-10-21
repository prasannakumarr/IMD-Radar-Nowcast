{-# LANGUAGE OverloadedStrings #-}

-- | Calibration data and runtime settings.
--
-- Each IMD site renders with a different Rainbow skin, so the handful of
-- numbers describing where things sit in the image cannot be discovered
-- reliably at runtime.  They are measured once and live here as plain data.
module RTW.Config
  ( Rect (..)
  , rectW
  , rectH
  , Product (..)
  , products
  , stillUrl
  , Place (..)
  , Settings (..)
  , loadSettings
  ) where

import Control.Monad (when)
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv, setEnv)
import Text.Read (readMaybe)

-- | A rectangle in image-pixel space, half-open on the far edge.
data Rect = Rect {rX0 :: !Int, rY0 :: !Int, rX1 :: !Int, rY1 :: !Int}

rectW, rectH :: Rect -> Int
rectW r = rX1 r - rX0 r
rectH r = rY1 r - rY0 r

-- | Everything needed to invert one IMD radar product image.
data Product = Product
  { pCode :: !Text
  -- ^ GIF stem, e.g. @caz_cni@
  , pLabel :: !Text
  , pLat :: !Double
  , pLon :: !Double
  -- ^ where the dish actually is
  , pRangeKm :: !Double
  , pBar :: !Rect
  -- ^ the reflectivity colour bar printed on the image
  , pDbzHi :: !Double
  , pDbzLo :: !Double
  -- ^ the values printed at its ends
  , pPanel :: !Rect
  -- ^ the radar panel to crop out
  , pSiteX :: !Double
  , pSiteY :: !Double
  -- ^ where the dish sits in the full image
  , pKmPerPx :: !Double
  }

-- | Ordered coarsest-first: later layers draw on top, so the fine X-band
-- picture sits above the wide S-band ones where they overlap.
products :: [Product]
products =
  [ Product
      { pCode = "caz_cni"
      , pLabel = "Chennai DWR MAXZ"
      , pLat = 13.083747
      , pLon = 80.290057
      , pRangeKm = 250
      , pBar = Rect 716 74 782 425
      , pDbzHi = 60
      , pDbzLo = 20
      , pPanel = Rect 0 198 499 698
      , pSiteX = 249.5
      , pSiteY = 447.7
      , pKmPerPx = 1.0
      }
  , Product
      { pCode = "caz_kkl"
      , pLabel = "Karaikal DWR MAXZ"
      , pLat = 10.9254
      , pLon = 79.8380
      , pRangeKm = 250
      , pBar = Rect 788 375 799 616
      , pDbzHi = 60
      , pDbzLo = 20
      , pPanel = Rect 0 199 520 720
      , pSiteX = 259.5
      , pSiteY = 459.0
      , pKmPerPx = 250 / 260
      }
  , -- X-band, sited on the southern edge of Chennai. Short range but ~10x
    -- the resolution of the S-band radars and far more sensitive to light
    -- rain.
    --
    -- Caveat worth knowing: X-band attenuates severely in heavy rain, so
    -- reflectivity *behind* an intense core is underestimated. Our fusion
    -- keeps the strongest report, which means the S-band radars win exactly
    -- when this one is being fooled -- the right behaviour, by luck.
    --
    -- Calibration: range rings measured at 211/422/633 px for 20/40/60 km
    -- (perfectly linear), centre cross at panel-local (899.5, 899.5).
    Product
      { pCode = "caz_plk"
      , pLabel = "Chennai X-DWR (Pallikaranai)"
      , pLat = 12.9451
      , pLon = 80.2115
      , pRangeKm = 85
      , pBar = Rect 2645 678 2695 2428
      , pDbzHi = 60
      , pDbzLo = 20
      , pPanel = Rect 30 629 1830 2429
      , pSiteX = 929.5
      , pSiteY = 1528.5
      , pKmPerPx = 20 / 211
      }
  ]

stillUrl :: Product -> String
stillUrl p = "https://mausam.imd.gov.in/Radar/" <> T.unpack (pCode p) <> ".gif"

-- | A labelled point drawn on the map. The first one is also the initial
-- map centre.
data Place = Place {plName :: !Text, plLat :: !Double, plLon :: !Double}

-- | Neutral, city-scale defaults. Deliberately rounded to three decimals
-- (~100 m): these are landmarks, not anybody's doorstep. Override with
-- @PLACES@ in your own @.env@ rather than editing this list.
defaultPlaces :: [Place]
defaultPlaces =
  [ Place "Chennai" 13.082 80.275
  , Place "Adyar" 13.006 80.258
  , Place "Tambaram" 12.926 80.118
  , Place "Vadapalani" 13.050 80.212
  ]

-- | @Name:lat:lon,Name:lat:lon@. Entries that do not parse are skipped
-- rather than crashing startup, and an entirely unparseable value falls
-- back to 'defaultPlaces' -- a typo in config should not leave a blank map.
parsePlaces :: Text -> [Place]
parsePlaces = mapMaybe one . T.splitOn ","
  where
    one entry = case T.splitOn ":" (T.strip entry) of
      [n, la, lo]
        | not (T.null (T.strip n))
        , Just lat <- readMaybe (T.unpack (T.strip la))
        , Just lon <- readMaybe (T.unpack (T.strip lo))
        , abs lat <= 90
        , abs lon <= 180 ->
            Just (Place (T.strip n) lat lon)
      _ -> Nothing

-- | Runtime settings. Secrets come from the environment, never from source.
data Settings = Settings
  { sPort :: !Int
  , sMapboxToken :: !(Maybe Text)
  , sMapboxStyle :: !(Maybe Text)
  -- ^ @username\/styleid@ of a published *classic* style; the modern
  -- Mapbox Standard style is vector-only and will not render as raster tiles.
  , sCartoKey :: !(Maybe Text)
  , sRefreshSec :: !Int
  , sPlaces :: ![Place]
  -- ^ Where to pin and centre the map. Config, not source, so that nobody
  -- has to commit the place they actually live in order to use this.
  }

-- | Real environment variables always win; @.env@ only fills the gaps.
-- That ordering is the point -- @.env@ is a developer convenience, and
-- production config should never be shadowed by a stray file on disk.
loadDotEnv :: FilePath -> IO ()
loadDotEnv path = do
  there <- doesFileExist path
  when there $ readFile path >>= mapM_ assign . lines
  where
    assign raw = case break (== '=') (trim raw) of
      (key, '=' : val)
        | not (null key)
        , not ("#" `isPrefixOf` key) -> do
            already <- lookupEnv (trim key)
            when (isNothing already) $ setEnv (trim key) (trim val)
      _ -> pure ()
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

loadSettings :: IO Settings
loadSettings = do
  loadDotEnv ".env"
  port <- readEnv "PORT" 8080
  refresh <- readEnv "REFRESH_SECONDS" 600
  carto <- textEnv "CARTO_KEY"
  token <- textEnv "MAPBOX_TOKEN"
  style <- textEnv "MAPBOX_STYLE"
  places <- maybe [] parsePlaces <$> textEnv "PLACES"
  pure
    Settings
      { sPort = port
      , sMapboxToken = token
      , sMapboxStyle = style
      , sCartoKey = carto
      , sRefreshSec = refresh
      , sPlaces = if null places then defaultPlaces else places
      }
  where
    readEnv k d = maybe d (fromMaybe d . readMaybe) <$> lookupEnv k
    textEnv k = (>>= nonEmpty . T.pack) <$> lookupEnv k
    nonEmpty t = if T.null (T.strip t) then Nothing else Just t
