-- | The pure core: an IMD radar GIF in, a georeferenced dBZ grid out.
--
-- Every step here is a total function over immutable values, so the whole
-- decode is one composition and nothing in it can fail at a distance:
--
-- > decode p = despeckle . classify (buildLut p img) . crop (pPanel p)
module RTW.Decode
  ( Grid (..)
  , dbzAt
  , decode
  , overlayPng
  , Bounds (..)
  , bounds
  , pxToLonLat
  , kmPerDeg
  ) where

import Codec.Picture
import Data.ByteString.Lazy qualified as BL
import Data.IntSet qualified as IS
import Data.Vector.Unboxed qualified as VU
import RTW.Config

-- | Reflectivity on a regular grid. @NaN@ means "no echo", which keeps the
-- whole thing in an unboxed vector; 'dbzAt' is the honest accessor.
data Grid = Grid {gW :: !Int, gH :: !Int, gVals :: !(VU.Vector Float)}

nan :: Float
nan = 0 / 0

dbzAt :: Grid -> Int -> Int -> Maybe Float
dbzAt g x y
  | x < 0 || y < 0 || x >= gW g || y >= gH g = Nothing
  | isNaN v = Nothing
  | otherwise = Just v
  where
    v = gVals g `VU.unsafeIndex` (y * gW g + x)

type RGB = (Float, Float, Float)

-- | The dBZ ruler, read off the colour bar IMD prints on the image itself.
-- Nothing is hardcoded: change the palette upstream and this follows.
newtype Lut = Lut (VU.Vector (Float, Float, Float, Float))

buildLut :: Product -> Image PixelRGB8 -> Lut
buildLut p img = Lut (VU.fromList (thin (map rung [0 .. rows - 1])))
  where
    bar = pBar p
    rows = max 1 (rectH bar)
    rung i =
      let (r, g, b) = rowMean (rY0 bar + i)
          t = fromIntegral i / fromIntegral (max 1 (rows - 1))
       in (r, g, b, realToFrac (pDbzHi p + t * (pDbzLo p - pDbzHi p)))
    rowMean y =
      let xs = [rX0 bar .. rX1 bar - 1]
          n = fromIntegral (max 1 (length xs))
          add (ar, ag, ab) x = let (r, g, b) = at img x y in (ar + r, ag + g, ab + b)
          (sr, sg, sb) = foldl add (0, 0, 0) xs
       in (sr / n, sg / n, sb / n)
    -- collapse runs of near-identical colour so the match is a real search
    thin [] = []
    thin (c : cs) = c : go c cs
      where
        go _ [] = []
        go prev (x : xs)
          | sqDist3 prev x > 9 = x : go x xs
          | otherwise = go prev xs
    sqDist3 (a, b, c, _) (d, e, f, _) = (a - d) ^ (2 :: Int) + (b - e) ^ (2 :: Int) + (c - f) ^ (2 :: Int)

at :: Image PixelRGB8 -> Int -> Int -> RGB
at img x y = (fromIntegral r, fromIntegral g, fromIntegral b)
  where
    PixelRGB8 r g b =
      pixelAt img (clamp 0 (imageWidth img - 1) x) (clamp 0 (imageHeight img - 1) y)
    clamp lo hi = max lo . min hi

-- | 2x2 box mean, undoing Rainbow's dithering onto the web-safe palette.
--
-- This is the step that earns its keep. On the Chennai skin the Bay of Bengal
-- is itself a dither pair whose two colours also belong to the 32.5 and 35 dBZ
-- echo dithers -- per-pixel matching cannot tell sea from drizzle, and floods
-- the ocean with phantom rain. The local mean separates them cleanly.
dedither :: Image PixelRGB8 -> Int -> Int -> RGB
dedither img x y = (s r1 r2 r3 r4, s g1 g2 g3 g4, s b1 b2 b3 b4)
  where
    (r1, g1, b1) = at img x y
    (r2, g2, b2) = at img (x + 1) y
    (r3, g3, b3) = at img x (y + 1)
    (r4, g4, b4) = at img (x + 1) (y + 1)
    s a b c d = (a + b + c + d) / 4

-- | Nearest colour on the ruler, or nothing if this pixel is too far from
-- every rung to be echo at all (coastline, terrain, labels).
nearest :: Float -> Lut -> RGB -> Float
nearest tol (Lut v) (r, g, b)
  | VU.null v = nan
  | bestSq <= tol * tol = bestVal
  | otherwise = nan
  where
    (bestSq, bestVal) = VU.foldl' step (1 / 0, nan) v
    step acc@(d0, _) (lr, lg, lb, dbz)
      | d < d0 = (d, dbz)
      | otherwise = acc
      where
        d = (lr - r) ^ (2 :: Int) + (lg - g) ^ (2 :: Int) + (lb - b) ^ (2 :: Int)

-- | Smallest echo blob we are willing to paint.
--
-- One square kilometre is exactly one pixel of the S-band radars, so the rule
-- reads: do not draw anything the coarser radars could not even resolve.
minEchoKm2 :: Double
minEchoKm2 = 1.0

decode :: Product -> Image PixelRGB8 -> Grid
decode p img = prune minEchoKm2 (pKmPerPx p) (despeckle (Grid w h raw))
  where
    panel = pPanel p
    w = max 0 (min (rectW panel) (imageWidth img - rX0 panel))
    h = max 0 (min (rectH panel) (imageHeight img - rY0 panel))
    lut = buildLut p img
    raw = VU.generate (w * h) $ \i ->
      let (y, x) = i `divMod` w
       in nearest 24 lut (dedither img (rX0 panel + x) (rY0 panel + y))

-- | Remove map furniture that collides with the echo palette: isolated
-- matches (real echo is contiguous), and near-white pixels away from any
-- other echo (white is both ~37.5 dBZ and the colour of the printed labels).
despeckle :: Grid -> Grid
despeckle g = g {gVals = final}
  where
    w = gW g
    h = gH g
    vals = gVals g
    solid = VU.map (not . isNaN) vals
    neighbours :: VU.Vector Int
    neighbours = VU.generate (w * h) $ \i ->
      let (y, x) = i `divMod` w
       in length
            [ ()
            | dx <- [-1, 0, 1]
            , dy <- [-1, 0, 1]
            , (dx, dy) /= (0, 0)
            , look solid (x + dx) (y + dy)
            ]
    pass1 = VU.zipWith (\v n -> if n >= 3 then v else nan) vals neighbours
    whitish v = not (isNaN v) && v > 36 && v < 39.5
    other = VU.map (\v -> not (isNaN v) && not (whitish v)) pass1
    nearOther = dilate w h 4 other
    final = VU.zipWith (\v ok -> if whitish v && not ok then nan else v) pass1 nearOther
    look vec x y
      | x < 0 || y < 0 || x >= w || y >= h = False
      | otherwise = vec `VU.unsafeIndex` (y * w + x)

-- | Drop echo blobs smaller than @minKm2@.
--
-- 'despeckle' judges a pixel by how many neighbours it has, which is a
-- /pixel/ criterion and therefore means different things at different
-- resolutions. At the S-band radars' 1 km\/px it removes anything under a
-- few km². At the X-band radar's 0.095 km\/px a 2x2 patch of 0.036 km² sails
-- straight through, and the map fills with sub-km² returns -- nocturnal
-- insects and sea clutter rather than rain. The floor has to be an area.
prune :: Double -> Double -> Grid -> Grid
prune minKm2 kmPerPx g
  | minPx <= 1 = g
  | otherwise = g {gVals = gVals g VU.// [(i, nan) | i <- doomed]}
  where
    w = gW g
    h = gH g
    minPx = ceiling (minKm2 / (kmPerPx * kmPerPx)) :: Int
    live = IS.fromList [i | i <- [0 .. w * h - 1], not (isNaN (gVals g `VU.unsafeIndex` i))]
    doomed = concat (filter ((< minPx) . length) (components live))

    components s = case IS.minView s of
      Nothing -> []
      Just (seed, rest) ->
        let (comp, rest') = flood [seed] [] rest
         in comp : components rest'

    flood [] acc rest = (acc, rest)
    flood (i : is) acc rest =
      let (y, x) = i `divMod` w
          nbrs =
            [ j
            | dx <- [-1, 0, 1]
            , dy <- [-1, 0, 1]
            , let nx = x + dx
            , let ny = y + dy
            , nx >= 0
            , ny >= 0
            , nx < w
            , ny < h
            , let j = ny * w + nx
            , IS.member j rest
            ]
       in flood (nbrs <> is) (i : acc) (foldr IS.delete rest nbrs)

dilate :: Int -> Int -> Int -> VU.Vector Bool -> VU.Vector Bool
dilate w h r v0 = iterate step v0 !! r
  where
    step v = VU.generate (w * h) $ \i ->
      let (y, x) = i `divMod` w
       in v `VU.unsafeIndex` i
            || any (\(dx, dy) -> look v (x + dx) (y + dy)) [(-1, 0), (1, 0), (0, -1), (0, 1)]
    look vec x y
      | x < 0 || y < 0 || x >= w || y >= h = False
      | otherwise = vec `VU.unsafeIndex` (y * w + x)

-- | 5 dBZ steps, transparent below 20, so the overlay sits over a road map.
palette :: [(Float, PixelRGBA8)]
palette =
  [ (20, PixelRGBA8 0xa8 0xe6 0xa1 216)
  , (25, PixelRGBA8 0x5f 0xcf 0x6a 216)
  , (30, PixelRGBA8 0xf4 0xe0 0x4d 216)
  , (35, PixelRGBA8 0xf7 0xa9 0x36 216)
  , (40, PixelRGBA8 0xee 0x6a 0x2e 216)
  , (45, PixelRGBA8 0xd6 0x28 0x28 216)
  , (50, PixelRGBA8 0xa4 0x13 0x3c 216)
  , (55, PixelRGBA8 0x7b 0x2c 0xbf 216)
  ]

clear :: PixelRGBA8
clear = PixelRGBA8 0 0 0 0

overlayPng :: Grid -> BL.ByteString
overlayPng g = encodePng (generateImage px (max 1 (gW g)) (max 1 (gH g)))
  where
    px x y = maybe clear colourOf (dbzAt g x y)
    colourOf v = foldl (\acc (lo, c) -> if v >= lo then c else acc) clear palette

-- Geo ----------------------------------------------------------------------

-- | Rainbow draws at a constant km/pixel and labels its graticule assuming a
-- spherical earth at 111 km per degree, so inverting it is this simple.
kmPerDeg :: Double
kmPerDeg = 111.0

data Bounds = Bounds {bSouth :: !Double, bWest :: !Double, bNorth :: !Double, bEast :: !Double}

degPerPx :: Product -> (Double, Double)
degPerPx p = (dlat, dlon)
  where
    dlat = pKmPerPx p / kmPerDeg
    dlon = pKmPerPx p / (kmPerDeg * cos (pLat p * pi / 180))

bounds :: Product -> Bounds
bounds p =
  Bounds
    { bSouth = pLat p - (fromIntegral (rY1 panel) - pSiteY p) * dlat
    , bWest = pLon p - (pSiteX p - fromIntegral (rX0 panel)) * dlon
    , bNorth = pLat p + (pSiteY p - fromIntegral (rY0 panel)) * dlat
    , bEast = pLon p + (fromIntegral (rX1 panel) - pSiteX p) * dlon
    }
  where
    panel = pPanel p
    (dlat, dlon) = degPerPx p

-- | Panel-local pixel to (lon, lat).
pxToLonLat :: Product -> Double -> Double -> (Double, Double)
pxToLonLat p col row = (lon, lat)
  where
    panel = pPanel p
    (dlat, dlon) = degPerPx p
    lon = pLon p + (fromIntegral (rX0 panel) + col - pSiteX p) * dlon
    lat = pLat p - (fromIntegral (rY0 panel) + row - pSiteY p) * dlat
