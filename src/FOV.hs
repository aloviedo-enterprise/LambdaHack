module FOV where

import Data.Map as M
import Data.Set as S
import Data.List as L
import Data.Ratio
import Data.Maybe
import Debug.Trace

import Geometry
import Level

type Interval = (Rational, Rational)
type Distance = Int
type Progress = Int
newtype Bump      = B Loc  deriving (Show)
type Line         = (Bump, Bump)
type ConvexHull   = [Bump]
type Edge         = (Line, ConvexHull)
type EdgeInterval = (Edge, Edge)
data WhichLine    = Shallow | Steep  deriving (Show, Eq)

data FovMode = Shadow | Permissive Int | Diagonal Int

-- | Perform a full scan for a given location. Returns the locations
-- that are currently visible.
fullscan :: FovMode -> Loc -> LMap -> Set Loc
fullscan fovMode loc lmap =
  case fovMode of
    Shadow ->         -- shadow casting with infinite range
      S.unions $
      L.map (\ tr ->
              scan (tr loc) lmap 1 (0,1))
      [tr0,tr1,tr2,tr3,tr4,tr5,tr6,tr7]
    Permissive n  ->  -- precise permissive with range n
      S.unions $
      L.map (\ tr ->
              pscan n (tr loc) lmap 1
                (((B(1, 0), B(0, 2*n)), []), ((B(0, 1), B(2*n, 0)), [])))
      [qtr0,qtr1,qtr2,qtr3]
    Diagonal n    ->  -- diagonal with range n
      S.unions $
      L.map (\ tr ->
              dscan n (tr loc) lmap 1
                (((B(0, 1), B(2*n, -2*n)), []), ((B(0, 0), B(2*n, 1+2*n)), [])))
      [qtr0,qtr1,qtr2,qtr3]

-- | The translation, rotation and symmetry functions for octants.
tr0 (oy,ox) (d,p) = (oy + d,ox + p)
tr1 (oy,ox) (d,p) = (oy + d,ox - p)
tr2 (oy,ox) (d,p) = (oy - d,ox + p)
tr3 (oy,ox) (d,p) = (oy - d,ox - p)
tr4 (oy,ox) (d,p) = (oy + p,ox + d)
tr5 (oy,ox) (d,p) = (oy + p,ox - d)
tr6 (oy,ox) (d,p) = (oy - p,ox + d)
tr7 (oy,ox) (d,p) = (oy - p,ox - d)

-- | The translation and rotation functions for quadrants.
qtr0, qtr1, qtr2, qtr3 :: Loc -> Bump -> Loc
qtr0 (oy, ox) (B(y, x)) = (oy - y, ox + x)  -- first quadrant
qtr1 (oy, ox) (B(y, x)) = (oy - x, ox - y)  -- then rotated clockwise 90 degrees
qtr2 (oy, ox) (B(y, x)) = (oy + y, ox - x)
qtr3 (oy, ox) (B(y, x)) = (oy + x, ox + y)


-- | A restrictive variant of Recursive Shadow Casting FOV with infinite range.
-- It's not designed for dungeons with diagonal walls, so they block visibility,
-- though they don't block movement. Such cases appear in LambdaHack only
-- when two corridors touch diagonally by accident and on the random pillars
-- levels.

-- | The current state of a scan is kept in a variable of Maybe Rational.
-- If Just something, we're in a visible interval. If Nothing, we're in
-- a shadowed interval.
scan :: ((Distance, Progress) -> Loc) -> LMap -> Distance -> Interval -> Set Loc
scan tr l d (s,e) =
    let ps = downBias (s * fromIntegral d)   -- minimal progress to check
        pe = upBias (e * fromIntegral d)     -- maximal progress to check
        st = if open (l `at` tr (d,ps)) then Just s   -- start in light
                                        else Nothing  -- start in shadow
    in
        -- trace (show (d,s,e,ps,pe)) $
        S.union (S.fromList [tr (d,p) | p <- [ps..pe]]) (scan' st ps pe)
  where
    scan' :: Maybe Rational -> Progress -> Progress -> Set Loc
    -- scan' st ps pe
    --   | trace (show (st,ps,pe)) False = undefined
    scan' (Just s) ps pe
      | s  >= e  = S.empty               -- empty interval
      | ps > pe  = scan tr l (d+1) (s,e) -- reached end, scan next
      | closed (l `at` tr (d,ps)) =
                   let ne = (fromIntegral ps - (1%2)) / (fromIntegral d + (1%2))
                   in  scan tr l (d+1) (s,ne) `S.union` scan' Nothing (ps+1) pe
                                      -- entering shadow
      | otherwise = scan' (Just s) (ps+1) pe
                                      -- continue in light
    scan' Nothing ps pe
      | ps > pe  = S.empty            -- reached end while in shadow
      | open (l `at` tr (d,ps)) =
                   let ns = (fromIntegral ps - (1%2)) / (fromIntegral d - (1%2))
                   in  scan' (Just ns) (ps+1) pe
                                      -- moving out of shadow
      | otherwise = scan' Nothing (ps+1) pe
                                      -- continue in shadow

downBias, upBias :: (Integral a, Integral b) => Ratio a -> b
downBias x = round (x - 1 % (denominator x * 3))
upBias   x = round (x + 1 % (denominator x * 3))


-- | Precise Permissive FOV with a given range.
-- Clean-room reimplemented based on http://roguebasin.roguelikedevelopment.org/index.php?title=Precise_Permissive_Field_of_View. See https://github.com/Mikolaj/LambdaHack/wiki/Fov-and-los for some more context. TODO: Scanning squares on horizontal lines in octants, not squares on diagonals in quadrants, may be much faster and a bit simpler.

-- | The current state of a scan is kept in Maybe (Line, ConvexHull).
-- If Just something, we're in a visible interval. If Nothing, we're in
-- a shadowed interval.
pscan :: Distance -> (Bump -> Loc) -> LMap -> Distance -> EdgeInterval ->
         Set Loc
pscan n ptr l d (s@(sl{-shallow line-}, sBumps), e@(el{-steep line-}, eBumps)) =
  -- trace (show (d,s,e,ps,pe)) $
  S.union
    (S.fromList [tr (d, p) | p <- [ps..pe]])
    (if d < n then start else S.empty)
    -- the area is diagonal, which is incorrect, but looks good enough
    where
      (ps, cs) = let (n, k) = pintersect sl d  -- minimal progress to check
                 in  (n `div` k, - (-n) `div` k)
      (pe, ce) = let (n, k) = pintersect el d  -- maximal progress to check
                     -- Corners are translucent, so they are invisible,
                     -- so if intersection is at a corner, choose the square
                     -- for pe that creates the smaller view.
                 in  (-1 - (-n) `div` k, n `div` k)
      start
        | open (l `at` tr (d, ps)) = pscan' (Just s) ps  -- start in light
        | ps < cs = pscan' Nothing (ps+1)                -- start in mid-wall
        | ps == cs = pscan' (Just s) ps                  -- start in a corner
        | otherwise = error $ "pscan: wrong start " ++ show (d, (ps, cs))

      dp2bump     (d, p) = B(p, d - p)
      bottomRight (d, p) = B(p, d - p + 1)
      tr = ptr . dp2bump

      pscan' :: Maybe Edge -> Progress -> Set Loc
      pscan' (Just s@(_, sBumps)) ps
        | ps > pe =                            -- reached end, scan next
            pscan n ptr l (d+1) (s, e)
        | closed (l `at` tr (d, ps)) =         -- entering shadow, steep bump
            let steepBump = bottomRight (d, ps)
                nel = pborderLine Steep steepBump sBumps
                neBumps = steepBump:eBumps
            in  S.union
                  (pscan n ptr l (d+1) (s, (nel, neBumps)))
                  (pscan' Nothing (ps+1))
        | otherwise = pscan' (Just s) (ps+1)   -- continue in light

      pscan' Nothing ps
        | ps > ce = S.empty                    -- reached absolute end
        | otherwise =                          -- out of shadow, shallow bump
            -- the light can be just through a corner of diagonal walls
            -- and the recursive call verifies that at the same ps coordinate
            let shallowBump = bottomRight (d, ps)
                nsl = pborderLine Shallow shallowBump eBumps
                nsBumps = shallowBump:sBumps
            in  pscan' (Just (nsl, nsBumps)) ps

{- THE Y COORDINATE COMES FIRST! (Y,X)!
A square is denoted by its bottom-left corner. Hero at (0,0).
Order of processing in the first quadrant is
9
58
247
@136
so the first processed square is at (0, 1). The order is reversed
wrt the shadow casting algorithm above. The line in the curent state
of scan' is not the steep line, but the shallow line,
and we start scanning from the bottom right.

The Loc coordinates are cartesian, the Bump coordinates are cartesian,
translated so that the hero is at (0, 0) and rotated so that he always
looks at the first quadrant, the (Distance, Progress) cordinates
are mangled and not used for geometry.
-}

-- | The y coordinate, represented as a fraction, of the intersection of
-- a given line and the line of diagonals of squares at distance d from (0, 0).
pintersect :: Line -> Distance -> (Int, Int)
pintersect (B(y, x), B(yf, xf)) d =
  ((1 + d)*(yf - y) + y*xf - x*yf, (xf - x) + (yf - y))
{-
The intersection point (yt, xt) satisfies the following equalities:
xt = 1 + d - yt
(yt - y) (xf - x) = (xt - x) (yf - y)
hence
(yt - y) (xf - x) = (xt - x) (yf - y)
yt (xf - x) - y xf = xt (yf - y) - x yf
yt (xf - x) - y xf = (1 + d) (yf - y) - yt (yf - y) - x yf
yt (xf - x) + yt (yf - y) = (1 + d) (yf - y) - x yf + y xf
yt = ((1 + d) (yf - y) + y xf - x yf) / (xf - x + yf - y)
-}

-- | Constructs steep or shallow line from the far point and the opposite
-- convex hull of bumps.
pborderLine :: WhichLine -> Bump -> ConvexHull -> Line
pborderLine which farPoint@(B(yf, xf)) hull =
  let steeper (B(y1, x1)) (B(y2, x2)) =
        (yf - y1)*(xf - x2) > (yf - y2)*(xf - x1)
      (extraBump, strongerBump) =
        case which of
          Shallow -> (B(1, 0), steeper)
          Steep   -> (B(0, 1), \ a b -> steeper b a)
      cross acc bump
        | strongerBump bump acc = bump
        | otherwise = acc
      strongestBump = L.foldl' cross extraBump hull
      line =
        -- trace (show (which, strongestBump, farPoint, hull)) $
        pdebugBorderLine $  -- TODO: disable when it becomes a bottleneck
        (strongestBump, farPoint)
  in  line

-- | Debug: checks postconditions of borderLine.
pdebugBorderLine :: Line -> Line
pdebugBorderLine line@(B(y1, x1), B(y2, x2))
  | y1 == y2 && x1 == x2 =
      error $ "pborderLine: wrongly defined line " ++ show line
  | x2 - x1 == - (y2 - y1) =
      error $ "pborderLine: diagonal line " ++ show line
  | crossL0 =
      error $ "pborderLine: crosses diagonal below 0 " ++ show line
  | crossG1 =
      error $ "pborderLine: crosses diagonal above 1 " ++ show line
  | otherwise = line
    where
      (n, k)  = pintersect line 0
      (q, r)  = if k == 0 then (0, 0) else n `divMod` k
      crossL0 = q < 0  -- q truncated toward negative infinity
      crossG1 = q >= 1 && (q > 1 || r /= 0)


-- | Digital FOV with a given range.
-- Specification is at http://roguebasin.roguelikedevelopment.org/index.php?title=Digital_field_of_view_implementation, but AFAIK, this algorithm (fast DFOV done similarly as PFOV) has never been implemented before. The algorithm is based on the PFOV algorithm, clean-room reimplemented based on http://roguebasin.roguelikedevelopment.org/index.php?title=Precise_Permissive_Field_of_View. See https://github.com/Mikolaj/LambdaHack/wiki/Fov-and-los for some more context.

-- | The current state of a scan is kept in Maybe (Line, ConvexHull).
-- If Just something, we're in a visible interval. If Nothing, we're in
-- a shadowed interval.
dscan :: Distance -> (Bump -> Loc) -> LMap -> Distance -> EdgeInterval ->
         Set Loc
dscan n tr l d (s@(sl{-shallow line-}, sBumps), e@(el{-steep line-}, eBumps)) =
  -- trace (show (d,s,e,ps,pe,start)) $
  S.union
    (S.fromList [tr (B(d, p)) | p <- [ps..pe]])
    (if d < n then start else S.empty)
    -- the scanned area is a square, which is a sphere in this metric; good
    where
      ps = let (n, k) = dintersect sl d       -- minimal progress to check
           in  n `div` k
      pe = let (n, k) = dintersect el d       -- maximal progress to check
               -- Corners obstruct view, so the steep line, constructed
               -- from corners, is itself not a part of the view,
               -- so if its intersection with the line of diagonals is only
               -- at a corner, choose the diamond leading to a smaller view.
           in  -1 - (-n) `div` k
      start
        | ps > pe = error $ "dscan: wrong start " ++ show (d, (ps, pe))
        | open (l `at` tr (B(d, ps))) =
            dscan' (Just s) (ps+1)            -- start in light, jump ahead
        | otherwise = dscan' Nothing (ps+1)   -- start in shadow, jump ahead

      dscan' :: Maybe Edge -> Progress -> Set Loc
      dscan' (Just s@(_, sBumps)) ps
        | ps > pe = dscan n tr l (d+1) (s, e) -- reached end, scan next
        | closed (l `at` tr steepBump) =      -- entering shadow
            S.union (dscan n tr l (d+1) (s, ne)) (dscan' Nothing (ps+1))
        | otherwise = dscan' (Just s) (ps+1)  -- continue in light
        where
          steepBump = B(d, ps)
          ne = (dborderLine Steep steepBump sBumps, steepBump:eBumps)

      dscan' Nothing ps
        | ps > pe = S.empty                   -- reached end while in shadow
        | open (l `at` tr shallowBump) =      -- moving out of shadow
            dscan' (Just ns) (ps+1)
        | otherwise = dscan' Nothing (ps+1)   -- continue in shadow
        where
          shallowBump = B(d, ps)
          ns = (dborderLine Shallow shallowBump eBumps, shallowBump:sBumps)

{- THE Y COORDINATE COMES FIRST! (Y,X)!
A diamond is denoted by its left corner. Hero at (0,0).
Order of processing in the first quadrant rotated by 45 degrees is
 45678
  123
   @
so the first processed diamond is at (-1, 1). The order is similar
as for the shadow casting algorithm above and reversed wrt PFOV.
The line in the curent state of scan' is called the shallow line,
but it's the one that delimits the view from the left, while the steep
line is on the right, opposite to PFOV. We start scanning from the left.

The Loc coordinates are cartesian, the Bump coordinates are cartesian,
translated so that the hero is at (0, 0) and rotated so that he always
looks at the first roatated quadrant, the (Distance, Progress) cordinates
coincide with the Bump coordinates, unlike in PFOV.
-}

-- | The x coordinate, represented as a fraction, of the intersection of
-- a given line and the line of diagonals of diamonds at distance d from (0, 0).
dintersect :: Line -> Distance -> (Int, Int)
dintersect (B(y, x), B(yf, xf)) d =
  ((d - y)*(xf - x) + x*(yf - y), yf - y)
{-
The intersection point (yt, xt) satisfies the following equalities:
yt = d
(yt - y) (xf - x) = (xt - x) (yf - y)
hence
(yt - y) (xf - x) = (xt - x) (yf - y)
(d - y) (xf - x) = (xt - x) (yf - y)
(d - y) (xf - x) + x (yf - y) = xt (yf - y)
xt = ((d - y) (xf - x) + x (yf - y)) / (yf - y)
-}

-- | Constructs steep or shallow line from the far point and the opposite
-- convex hull of bumps.
dborderLine :: WhichLine -> Bump -> ConvexHull -> Line
dborderLine which farPoint@(B(yf, xf)) hull =
  let steeper (B(y1, x1)) (B(y2, x2)) =
        (yf - y1)*(xf - x2) > (yf - y2)*(xf - x1)
      (extraBump, strongerBump) =
        case which of
          Shallow -> (B(0, 1), \ a b -> steeper b a)
          Steep   -> (B(0, 0), steeper)
      cross acc bump
        | strongerBump bump acc = bump
        | otherwise = acc
      strongestBump = L.foldl' cross extraBump hull
      line =
        -- trace (show (which, strongestBump, farPoint, hull)) $
        ddebugBorderLine $  -- TODO: disable when it becomes a bottleneck
        (strongestBump, farPoint)
  in  line

-- | Debug: checks postconditions of borderLine.
ddebugBorderLine :: Line -> Line
ddebugBorderLine line@(B(y1, x1), B(y2, x2))
  | y1 == y2 && x1 == x2 =
      error $ "dborderLine: wrongly defined line " ++ show line
  | y2 - y1 == 0 =
      error $ "dborderLine: horizontal line " ++ show line
  | crossL0 =
      error $ "dborderLine: crosses diagonal below 0 " ++ show line
  | crossG1 =
      error $ "dborderLine: crosses diagonal above 1 " ++ show line
  | otherwise = line
    where
      (n, k)  = dintersect line 0
      (q, r)  = if k == 0 then (0, 0) else n `divMod` k
      crossL0 = q < 0  -- q truncated toward negative infinity
      crossG1 = q >= 1 && (q > 1 || r /= 0)

-- | Adds a bump to the convex hull of bumps represented as a list.
-- TODO: Reintroduce this function, because hulls can't be optimized
-- in borderLine. Can be optimized by removing some points from the list,
-- also taking into account that (1, 0), etc. belong to the hull.
addHull :: Bump -> ConvexHull -> ConvexHull
addHull loc l = loc : l
