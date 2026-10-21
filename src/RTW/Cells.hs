{-# LANGUAGE OverloadedStrings #-}

-- | Storm cells, found purely from a decoded grid.
--
-- Connected components are grown with an explicit worklist over an 'IS.IntSet'
-- of candidate pixels rather than a mutable label array: echo is sparse (a few
-- hundred pixels out of a quarter million), so the set is small and the whole
-- thing stays a pure fold.
module RTW.Cells
  ( Cell (..)
  , findCells
  , fuse
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.IntSet qualified as IS
import Data.List (sortOn)
import RTW.Config
import RTW.Decode

data Cell = Cell
  { cLat :: !Double
  , cLon :: !Double
  , cDbz :: !Double
  , cAreaKm2 :: !Double
  , cFrom :: !String
  }

instance ToJSON Cell where
  toJSON c =
    object
      [ "lat" .= cLat c
      , "lon" .= cLon c
      , "dbz" .= cDbz c
      , "areaKm2" .= cAreaKm2 c
      , "from" .= cFrom c
      ]

-- | Smallest blob we are willing to call a storm cell.
--
-- This must be an /area/, not a pixel count. The S-band radars run at
-- 1 km\/px where 4 pixels is a 4 km² shower, but the X-band radar runs at
-- 0.095 km\/px where the same 4 pixels is 0.036 km² -- a speck of ground
-- clutter. Counting pixels silently floods the map with phantom cells the
-- moment a finer radar joins.
minCellKm2 :: Double
minCellKm2 = 4.0

-- | Blobs at or above @threshold@ dBZ, located by reflectivity-weighted
-- centroid so a cell's marker sits on its core rather than its outline.
findCells :: Double -> Product -> Grid -> [Cell]
findCells threshold p g = map toCell (filter ((>= minPx) . length) (grow seeds))
  where
    minPx = max 4 (ceiling (minCellKm2 / (pKmPerPx p ** 2)))
    w = gW g
    h = gH g
    val i = dbzAt g (i `mod` w) (i `div` w)
    strong i = maybe False (\v -> realToFrac v >= threshold) (val i)
    seeds = IS.fromList (filter strong [0 .. w * h - 1])

    grow s = case IS.minView s of
      Nothing -> []
      Just (seed, rest) ->
        let (comp, rest') = flood [seed] IS.empty rest
         in IS.toList comp : grow rest'

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
       in flood (nbrs ++ is) (IS.insert i acc) (foldr IS.delete rest nbrs)

    toCell idxs =
      Cell
        { cLat = lat
        , cLon = lon
        , cDbz = peak
        , cAreaKm2 = fromIntegral (length idxs) * pKmPerPx p ** 2
        , cFrom = show (pLabel p)
        }
      where
        pts =
          [ (fromIntegral (i `mod` w), fromIntegral (i `div` w), realToFrac v)
          | i <- idxs
          , Just v <- [val i]
          ] ::
            [(Double, Double, Double)]
        total = sum [v | (_, _, v) <- pts]
        cx = sum [x * v | (x, _, v) <- pts] / total
        cy = sum [y * v | (_, y, v) <- pts] / total
        peak = maximum [v | (_, _, v) <- pts]
        (lon, lat) = pxToLonLat p cx cy

-- | Merge cells that overlapping radars both see, keeping the strongest
-- report of each cluster. Chennai and Karaikal share a lot of sky.
fuse :: Double -> [Cell] -> [Cell]
fuse radiusKm = foldl add [] . sortOn (negate . cDbz)
  where
    add kept c
      | any ((< radiusKm) . separation c) kept = kept
      | otherwise = kept <> [c]
    separation a b = sqrt (dy * dy + dx * dx)
      where
        dy = (cLat a - cLat b) * kmPerDeg
        dx = (cLon a - cLon b) * kmPerDeg * cos (cLat a * pi / 180)
