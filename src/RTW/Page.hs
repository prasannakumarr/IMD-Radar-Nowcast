{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The page shell.
--
-- It is deliberately static and carries no data: it paints immediately, then
-- asks @\/api\/state@ for whatever the server currently holds. That split is
-- what keeps first paint instant no matter how slow IMD is being.
module RTW.Page (page) where

import Data.Aeson (encode)
import Data.FileEmbed (embedStringFile)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import RTW.Config (Place (..), Settings (..))

-- | A tile source and the Leaflet options that go with it.
data Basemap = Basemap {bmUrl :: !Text, bmOpts :: !Text}

-- | Decided purely from configuration: Mapbox if a token and style are set,
-- then CARTO, then keyless Esri so the map still works with no credentials.
chooseBasemap :: Settings -> Basemap
chooseBasemap s = case (sMapboxToken s, sMapboxStyle s) of
  (Just token, Just style) ->
    Basemap
      ( "https://api.mapbox.com/styles/v1/"
          <> style
          <> "/tiles/512/{z}/{x}/{y}@2x?access_token="
          <> token
      )
      -- Mapbox serves 512 px tiles and Leaflet assumes 256. Without these two
      -- options every label renders at double size and the zoom levels are
      -- silently off by one -- it looks like a styling mistake, not a bug.
      "{ attribution: '&copy; Mapbox &copy; OpenStreetMap', maxZoom: 18,\n\
      \  tileSize: 512, zoomOffset: -1 }"
  _ -> case sCartoKey s of
    Just k ->
      Basemap
        ("https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png?key=" <> k)
        "{ attribution: '&copy; OpenStreetMap contributors &copy; CARTO', maxZoom: 18 }"
    Nothing ->
      Basemap
        "https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}"
        "{ attribution: 'Tiles &copy; Esri', maxZoom: 18 }"

page :: Settings -> Text
page s =
  T.replace "__TILES__" (bmUrl bm)
    . T.replace "__TILEOPTS__" (bmOpts bm)
    -- Via aeson rather than string-stitching: the place list comes from the
    -- environment, and this is the only untrusted-ish value that reaches the
    -- page. Encoding it properly is what keeps it data instead of script.
    . T.replace "__PLACES__" (placesJson (sPlaces s))
    $ template
  where
    bm = chooseBasemap s
    -- @[[name, lat, lon], ...]@ -- the shape the page already expects.
    placesJson =
      TL.toStrict
        . TLE.decodeUtf8
        . encode
        . map (\(Place n la lo) -> (n, la, lo))

template :: Text
template = $(embedStringFile "static/index.html")
