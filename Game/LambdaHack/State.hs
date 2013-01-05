{-# LANGUAGE OverloadedStrings #-}
-- | Game state and persistent player cli types and operations.
module Game.LambdaHack.State
  ( -- * Game state
    TgtMode(..), Cursor(..)
  , State(..), defStateGlobal, defStateLocal
  , StateServer(..), defStateServer
  , StateClient(..), defStateClient, defHistory
  , StateDict
    -- * Type of na actor target
  , Target(..), updateTarget
    -- * Accessor
  , getArena, getTime, isControlledFaction, isSpawningFaction
    -- * State update
  , updateCursor, updateDungeon, updateDiscoveries
  , updateTime, updateArena, updateSide
    -- * Textual description
  , lookAt
    -- * Debug flags
  , DebugModeSer(..), defDebugModeSer, cycleTryFov
  , DebugModeCli(..), defDebugModeCli, toggleMarkVision, toggleMarkSmell
  , toggleOmniscient
  ) where

import Control.Monad
import Data.Binary
import qualified Data.IntMap as IM
import qualified Data.Map as M
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Game.LambdaHack.Vector
import qualified NLP.Miniutter.English as MU
import qualified System.Random as R
import System.Time

import Game.LambdaHack.Actor
import Game.LambdaHack.Config
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Content.TileKind
import Game.LambdaHack.Faction
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Key as K
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Point
import Game.LambdaHack.PointXY
import Game.LambdaHack.Time

-- | View on game state. Clients never update @sdungeon@ and @sfaction@,
-- but the server updates it for them depending on client exploration.
data State = State
  { sdungeon :: !Dungeon      -- ^ remembered dungeon
  , sdepth   :: !Int          -- ^ remembered dungeon depth
  , sdisco   :: !Discoveries  -- ^ remembered item discoveries
  , sfaction :: !FactionDict  -- ^ remembered sides still in game
  , scops    :: Kind.COps     -- ^ remembered content
  , splayer  :: !ActorId      -- ^ selected actor
  , sside    :: !FactionId    -- ^ selected faction
  , sarena   :: !LevelId      -- ^ selected level
  }
  deriving Show

-- | Global, server state.
data StateServer = StateServer
  { sdiscoRev :: !DiscoRev      -- ^ reverse map, used for item creation
  , sflavour  :: !FlavourMap    -- ^ association of flavour to items
  , scounter  :: !Int           -- ^ stores next actor index
  , srandom   :: !R.StdGen      -- ^ current random generator
  , sconfig   :: !Config        -- ^ this game's config (including initial RNG)
  , squit     :: !(Maybe Bool)  -- ^ just going to save the game
  , sdebugSer :: !DebugModeSer  -- ^ debugging mode
  }
  deriving Show

-- | Client state, belonging to a single faction.
-- Some of the data, e.g, the history, carries over
-- from game to game, even across playing sessions.
data StateClient = StateClient
  { scursor   :: !Cursor        -- ^ cursor position and level to return to
  , starget   :: !(IM.IntMap Target)  -- ^ targets of all actors in the dungeon
  , srunning  :: !(Maybe (Vector, Int))  -- ^ direction and distance of running
  , sreport   :: !Report        -- ^ current messages
  , shistory  :: !History       -- ^ history of messages
  , slastKey  :: !(Maybe K.KM)  -- ^ last command key pressed
  , sdebugCli :: !DebugModeCli  -- ^ debugging mode
  }

-- | All client and local state, indexed by faction identifier.
type StateDict = IM.IntMap (StateClient, State)

-- | All factions in the game, indexed by faction identifier.
type FactionDict = IM.IntMap Faction

-- | Current targeting mode of the player.
data TgtMode =
    TgtOff       -- ^ not in targeting mode
  | TgtExplicit  -- ^ the player requested targeting mode explicitly
  | TgtAuto      -- ^ the mode was entered (and will be exited) automatically
  deriving (Show, Eq)

-- | Current targeting cursor parameters.
data Cursor = Cursor
  { ctargeting :: !TgtMode  -- ^ targeting mode
  , cposLn     :: !LevelId  -- ^ cursor level
  , cposition  :: !Point    -- ^ cursor coordinates
  , ceps       :: !Int      -- ^ a parameter of the tgt digital line
  }
  deriving Show

data DebugModeSer = DebugModeSer
  { stryFov :: !(Maybe FovMode) }
  deriving Show

data DebugModeCli = DebugModeCli
  { smarkVision :: !Bool
  , smarkSmell  :: !Bool
  , somniscient :: !Bool
  }
  deriving Show

-- TODO: add a flag 'fresh' and when saving levels, don't save
-- and when loading regenerate this level.
unknownLevel :: Kind.Ops TileKind -> X -> Y
             -> Text -> (Point, Point) -> Int
             -> Level
unknownLevel Kind.Ops{ouniqGroup} lxsize lysize ldesc lstair lclear =
  let unknownId = ouniqGroup "unknown space"
  in Level { lactor = IM.empty
           , linv = IM.empty
           , litem = IM.empty
           , ltile = unknownTileMap unknownId lxsize lysize
           , lxsize = lxsize
           , lysize = lysize
           , lsmell = IM.empty
           , ldesc
           , lstair
           , lseen = 0
           , lclear
           , ltime = timeZero
           , lsecret = IM.empty
           }

unknownTileMap :: Kind.Id TileKind -> Int -> Int -> TileMap
unknownTileMap unknownId cxsize cysize =
  let bounds = (origin, toPoint cxsize $ PointXY (cxsize - 1, cysize - 1))
  in Kind.listArray bounds (repeat unknownId)

defHistory :: IO History
defHistory = do
  dateTime <- getClockTime
  let curDate = MU.Text $ T.pack $ calendarTimeToString $ toUTCTime dateTime
  return $ singletonHistory $ singletonReport
         $ makeSentence ["Player history log started on", curDate]

-- | Initial complete global game state.
defStateGlobal :: Dungeon -> Int -> Discoveries
                   -> FactionDict -> Kind.COps -> FactionId -> LevelId
                   -> State
defStateGlobal sdungeon sdepth sdisco sfaction scops sside sarena =
  State
    { splayer = invalidActorId  -- no heroes yet alive
    , ..
    }

-- TODO: make lstair secret until discovered; use this later on for
-- goUp in targeting mode (land on stairs of on the same location up a level
-- if this set of stsirs is unknown).
-- | Initial per-faction local game state.
defStateLocal :: Dungeon
                  -> Int -> Discoveries -> FactionDict
                  -> Kind.COps -> FactionId -> LevelId
                  -> State
defStateLocal globalDungeon
              sdepth sdisco sfaction
              scops@Kind.COps{cotile} sside sarena = do
  State
    { splayer  = invalidActorId  -- no heroes yet alive
    , sdungeon =
      M.map (\Level{lxsize, lysize, ldesc, lstair, lclear} ->
              unknownLevel cotile lxsize lysize ldesc lstair lclear)
            globalDungeon
    , ..
    }

-- | Initial game server state.
defStateServer :: DiscoRev -> FlavourMap -> R.StdGen -> Config
                   -> StateServer
defStateServer sdiscoRev sflavour srandom sconfig =
  StateServer
    { scounter  = 0
    , squit     = Nothing
    , sdebugSer = defDebugModeSer
    , ..
    }

-- | Initial game client state.
defStateClient :: Point -> LevelId -> StateClient
defStateClient ppos sarena = do
  StateClient
    { scursor   = Cursor TgtOff sarena ppos 0
    , starget   = IM.empty
    , srunning  = Nothing
    , sreport   = emptyReport
    , shistory  = emptyHistory
    , slastKey  = Nothing
    , sdebugCli = defDebugModeCli
    }

defDebugModeSer :: DebugModeSer
defDebugModeSer = DebugModeSer
  { stryFov = Nothing }

defDebugModeCli :: DebugModeCli
defDebugModeCli = DebugModeCli
  { smarkVision = False
  , smarkSmell  = False
  , somniscient = False
  }

-- | Tell whether the faction is human-controlled.
isControlledFaction :: State -> FactionId -> Bool
isControlledFaction s fid = isNothing $ gAiSelected $ sfaction s IM.! fid

-- | Tell whether the faction is human-controlled.
isSpawningFaction :: State -> FactionId -> Bool
isSpawningFaction s fid =
  let Kind.Ops{okind} = Kind.cofact (scops s)
      kind = okind $ gkind $ sfaction s IM.! fid
  in fspawn kind > 0

-- | Update cursor parameters within state.
updateCursor :: (Cursor -> Cursor) -> StateClient -> StateClient
updateCursor f s = s { scursor = f (scursor s) }

-- | Update cursor parameters within state.
updateTarget :: ActorId -> (Maybe Target -> Maybe Target) -> StateClient
             -> StateClient
updateTarget actor f s = s { starget = IM.alter f actor (starget s) }

-- | Update item discoveries within state.
updateDiscoveries :: (Discoveries -> Discoveries) -> State -> State
updateDiscoveries f s = s { sdisco = f (sdisco s) }

-- | Update dungeon data within state.
updateDungeon :: (Dungeon -> Dungeon) -> State -> State
updateDungeon f s = s {sdungeon = f (sdungeon s)}

-- | Get current level from the dungeon data.
getArena :: State -> Level
getArena State{sarena, sdungeon} = sdungeon M.! sarena

-- | Update current arena data within state.
updateArena :: (Level -> Level) -> State -> State
updateArena f s = updateDungeon (M.adjust f (sarena s)) s

-- | Update current side data within state.
updateSide :: (Faction -> Faction) -> State -> State
updateSide f s = s {sfaction = IM.adjust f (sside s) (sfaction s)}

-- | Get current time from the dungeon data.
getTime :: State -> Time
getTime State{sarena, sdungeon} = ltime $ sdungeon M.! sarena

-- | Update time within state.
updateTime :: (Time -> Time) -> State -> State
updateTime f s = updateArena (\lvl@Level{ltime} -> lvl {ltime = f ltime}) s

cycleTryFov :: StateServer -> StateServer
cycleTryFov s@StateServer{sdebugSer=sdebugSer@DebugModeSer{stryFov}} =
  s {sdebugSer = sdebugSer {stryFov = case stryFov of
                               Nothing          -> Just (Digital 100)
                               Just (Digital _) -> Just Permissive
                               Just Permissive  -> Just Shadow
                               Just Shadow      -> Just Blind
                               Just Blind       -> Nothing }}

toggleMarkVision :: StateClient -> StateClient
toggleMarkVision s@StateClient{sdebugCli=sdebugCli@DebugModeCli{smarkVision}} =
  s {sdebugCli = sdebugCli {smarkVision = not smarkVision}}

toggleMarkSmell :: StateClient -> StateClient
toggleMarkSmell s@StateClient{sdebugCli=sdebugCli@DebugModeCli{smarkSmell}} =
  s {sdebugCli = sdebugCli {smarkSmell = not smarkSmell}}

toggleOmniscient :: StateClient -> StateClient
toggleOmniscient s@StateClient{sdebugCli=sdebugCli@DebugModeCli{somniscient}} =
  s {sdebugCli = sdebugCli {somniscient = not somniscient}}

instance Binary State where
  put State{..} = do
    put sdungeon
    put sdepth
    put sdisco
    put sfaction
    put splayer
    put sside
    put sarena
  get = do
    sdungeon <- get
    sdepth <- get
    sdisco <- get
    sfaction <- get
    splayer <- get
    sside <- get
    sarena <- get
    let scops = undefined  -- overwritten by recreated cops
    return State{..}

instance Binary StateServer where
  put StateServer{..} = do
    put sdiscoRev
    put sflavour
    put scounter
    put (show srandom)
    put sconfig
  get = do
    sdiscoRev <- get
    sflavour <- get
    scounter <- get
    g <- get
    sconfig <- get
    let squit = Nothing
        srandom = read g
        sdebugSer = defDebugModeSer
    return StateServer{..}

instance Binary StateClient where
  put StateClient{..} = do
    put scursor
    put starget
    put srunning
    put sreport
    put shistory
  get = do
    scursor <- get
    starget <- get
    srunning <- get
    sreport <- get
    shistory <- get
    let slastKey = Nothing
        sdebugCli = defDebugModeCli
    return StateClient{..}

instance Binary TgtMode where
  put TgtOff      = putWord8 0
  put TgtExplicit = putWord8 1
  put TgtAuto     = putWord8 2
  get = do
    tag <- getWord8
    case tag of
      0 -> return TgtOff
      1 -> return TgtExplicit
      2 -> return TgtAuto
      _ -> fail "no parse (TgtMode)"

instance Binary Cursor where
  put Cursor{..} = do
    put ctargeting
    put cposLn
    put cposition
    put ceps
  get = do
    ctargeting <- get
    cposLn     <- get
    cposition  <- get
    ceps       <- get
    return Cursor{..}

-- | The type of na actor target.
data Target =
    TEnemy ActorId Point  -- ^ target an actor with its last seen position
  | TPos Point            -- ^ target a given position
  deriving (Show, Eq)

instance Binary Target where
  put (TEnemy a ll) = putWord8 0 >> put a >> put ll
  put (TPos pos) = putWord8 1 >> put pos
  get = do
    tag <- getWord8
    case tag of
      0 -> liftM2 TEnemy get get
      1 -> liftM TPos get
      _ -> fail "no parse (Target)"

-- TODO: probably move somewhere (Level?)
-- | Produces a textual description of the terrain and items at an already
-- explored position. Mute for unknown positions.
-- The detailed variant is for use in the targeting mode.
lookAt :: Bool       -- ^ detailed?
       -> Bool       -- ^ can be seen right now?
       -> State      -- ^ game state
       -> Point      -- ^ position to describe
       -> Text       -- ^ an extra sentence to print
       -> Text
lookAt detailed canSee loc pos msg
  | detailed =
    let tile = lvl `at` pos
    in makeSentence [MU.Text $ oname tile] <+> msg <+> isd
  | otherwise = msg <+> isd
 where
  Kind.COps{coitem, cotile=Kind.Ops{oname}} = scops loc
  lvl = getArena loc
  is  = lvl `atI` pos
  prefixSee = MU.Text $ if canSee then "you see" else "you remember"
  nWs = partItemNWs coitem (sdisco loc)
  isd = case is of
          [] -> ""
          _ | length is <= 2 ->
            makeSentence [prefixSee, MU.WWandW $ map nWs is]
          _ | detailed -> "Objects:"
          _ -> "Objects here."
