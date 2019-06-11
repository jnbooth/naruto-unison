module Model.Ninja
  ( Ninja(..), new, factory
  , Flag(..)
  , playing
  , alive, minHealth, healthLost
  , adjustHealth, setHealth, sacrifice
  , fromSelf
  , effects, effectsFrom
  , is, isAny, isChanneling
  , has, hasOwn, hasDefense, hasStatus, hasTrap
  , numActive, numStacks, numHelpful, defenseAmount
  , take, drop
  , setLast
  , decr
  , decrStats

  , cancelChannel
  , clear, clearBarrier, clearDefense, clearCounters, clearTrap, clearVariants
  , cure
  , cureBane
  , kill
  , hasten
  , prolong, prolong'
  , purge
  , refresh
  , addStatus, addOwnStacks, addOwnDefense
  , removeStack, removeStacks
  , resetCharges

  , kabuto
  ) where

import ClassyPrelude.Yesod hiding (Status, drop, group, head, init, last, take, mapMaybe)
import qualified Data.List as List
import           Data.List.NonEmpty ((!!), NonEmpty(..), group, init, last)
import qualified Data.Text as Text

import           Core.Util ((—), (∈), (∉), enumerate, incr, intersects, mapMaybe, sync)
import qualified Class.Classed as Classed
import qualified Class.Parity as Parity
import           Class.Parity (Parity)
import qualified Class.Labeled as Labeled
import qualified Class.TurnBased as TurnBased
import           Model.Internal (Ninja(..), Flag(..), ignore)
import qualified Model.Channel as Channel
import qualified Model.Character as Character
import qualified Model.Defense as Defense
import qualified Model.Effect as Effect
import           Model.Effect (Effect(..))
import           Model.Class (Class(..))
import           Model.Character (Character)
import qualified Model.Trap as Trap
import           Model.Trap (Trigger(..))
import qualified Model.Skill as Skill
import           Model.Skill (Skill)
import           Model.Slot (Slot)
import qualified Model.Status as Status
import           Model.Status (Status)
import qualified Model.Variant as Variant

-- | Constructs a 'Ninja' with starting values from a character and an index.
new :: Character -> Slot -> Ninja
new c slot = Ninja { slot       = slot
                   , health    = 100
                   , character = c
                   , defense   = []
                   , barrier   = []
                   , statuses  = []
                   , charges   = replicate 4 0
                   , cooldowns = mempty
                   , variants  = replicate 4 $ Variant.none :| []
                   , copies    = replicate 4 Nothing
                   , channels  = []
                   , newChans   = []
                   , traps     = mempty
                   , face      = []
                   , parrying  = []
                   , tags      = []
                   , lastSkill = Nothing
                   , flags     = mempty
                   }

-- | Factory resets a 'Ninja' to its starting values.
factory :: Ninja -> Ninja
factory n = new (character n) $ slot n

alive :: Ninja -> Bool
alive = (> 0) . health

playing :: ∀ a. Parity a => a -> Ninja -> Bool
playing p n = alive n && Parity.allied p n

fromSelf :: Ninja -> Status -> Bool
fromSelf n st = Status.source st == slot n || Status.user st == slot n

effects :: Ninja -> [Effect]
effects n = [ef | st <- statuses n
                , ef <- Status.effects $ Status.unfold st
                , ef ∉ ignore n]

effectsFrom :: Slot -> Ninja -> [Effect]
effectsFrom user n = [ef | st <- statuses n
                         , Status.user st == user
                         , ef <- Status.effects st]

is :: Effect -> Ninja -> Bool
is ef = (ef ∈) . effects

isAny :: (Class -> Effect) -> Ninja -> Bool
isAny efs = ((efs <$> enumerate) `intersects`) . effects

isChanneling :: Text -> Ninja -> Bool
isChanneling name = any ((name ==) . Skill.name . Channel.skill) . channels

has :: Text -> Slot -> Ninja -> Bool
has statusName statusSource = any match . statuses
  where
    match st = Status.name st == statusName
               && ( statusSource == Status.source st
                 || statusSource == Status.user st
                 || statusSource == Status.root st
                  )
               && ( Unshifted ∈ Status.classes st
                 || Shifted ∉ Status.classes st
                  )

hasStatus :: Status -> Ninja -> Bool
hasStatus st = has (Status.name st) (Status.source st)

hasDefense :: Text -> Slot -> Ninja -> Bool
hasDefense name source = any (Labeled.match name source) . defense

defenseAmount :: Text -> Slot -> Ninja -> Int
defenseAmount name source n =
    sum [ Defense.amount d | d <- defense n
                           , Defense.source d == source
                           , Defense.name d == name
                           ]

hasTrap :: Text -> Slot -> Ninja -> Bool
hasTrap name source = any match . traps
    where
      match trap =
          Trap.name trap == name && Trap.source trap == source
          && ( Unshifted ∈ Trap.classes trap
            || Shifted ∉ Trap.classes trap
             )

hasOwn :: Text -> Ninja -> Bool
hasOwn name n = has name (slot n) n
                || isChanneling name n
                || hasDefense name (slot n) n

numActive :: Text -> Ninja -> Int
numActive name n
  | stacks > 0         = stacks
  | hasOwn name n      = 1
  | otherwise          = 0
  where
    stacks = numStacks name (slot n) n

numStacks :: Text -> Slot -> Ninja -> Int
numStacks name source n = sum . (Status.amount <$>) .
                          filter (Labeled.match name source) $
                          statuses n

numHelpful :: Ninja -> Int
numHelpful n = length stats + length defs
  where
    stats = List.nubBy Labeled.eq [ st | st <- statuses n
                                  , any Effect.helpful $ Status.effects st
                                  , slot n /= Status.source st
                                  , Parity.allied (slot n) $ Status.source st
                                  , Hidden ∉ Status.classes st
                                  ]
    defs  = List.nubBy Labeled.eq [ d | d <- defense n
                                  , slot n /= Defense.source d
                                  , Parity.allied (slot n) $ Defense.source d
                                  ]

-- | 1 if the 'Ninja' is affected by 'Endure', otherwise 0.
minHealth :: Ninja -> Int
minHealth n
  | is Endure n = 1
  | otherwise   = 0

adjustHealth :: (Int -> Int) -> Ninja -> Ninja
adjustHealth f n = n { health = min 100 . max (minHealth n) . f $ health n }

setHealth :: Int -> Ninja -> Ninja
setHealth = adjustHealth . const

sacrifice :: Int -> Int -> Ninja -> Ninja
sacrifice minhp hp = adjustHealth $ max minhp . (— hp)

healthLost :: Ninja -> Ninja -> Int
healthLost n n' = max 0 $ health n - health n'

-- | Obtains an 'Effect' and removes its 'Status' from its owner.
take :: (Effect -> Bool) -> Ninja -> Maybe (Ninja, Effect, Status)
take matcher n = do
    match <- find (any matcher . Status.effects) $ statuses n
    let removed = Status.remove match $ statuses n
    case Status.effects match of
        [a] -> return (n { statuses = removed }, a, match)
        efs -> do
            a <- find matcher efs
            return (n { statuses = removed }, a, match)

drop :: (Effect -> Bool) -> Ninja -> Maybe Ninja
drop = map fst3 . take
  where
    fst3 (Just (n, _, _)) = Just n
    fst3 Nothing          = Nothing

setLast :: Skill -> Ninja -> Ninja
setLast skill n = n { lastSkill = Just skill }

-- \ While concluding 'runTurn', prevents refreshed 'Status'es from having
-- doubled effects due to there being both an old version and a new version.
decrStats :: Ninja -> Ninja
decrStats n = n { statuses = expire <$> statuses n }
  where
    expire st
      | Status.dur st == 1 = st { Status.effects = [] }
      | otherwise          = st

-- | Applies 'TurnBased.decr' to all of a 'Ninja's 'TurnBased' elements.
decr :: Ninja -> Ninja
decr n = case findMatch $ statuses n of
    Just (Snapshot n') -> decr n' -- TODO
    _ -> n { defense   = mapMaybe TurnBased.decr $ defense n
           , statuses  = foldStats . mapMaybe TurnBased.decr $ statuses n
           , barrier   = mapMaybe TurnBased.decr $ barrier n
           , face      = mapMaybe TurnBased.decr $ face n
           , channels  = mapMaybe TurnBased.decr $ newChans n ++ channels n
           , tags      = mapMaybe TurnBased.decr $ tags n
           , traps     = mapMaybe TurnBased.decr $ traps n
           , newChans  = mempty
           , variants  = turnDecr' <$> variants n
           , copies    = (>>= TurnBased.decr) <$> copies n
           , cooldowns = ((max 0 . subtract 1) <$>) <$> cooldowns n
           , parrying  = mempty
           , flags     = mempty
           }
  where
    findMatch          = find match . reverse . concatMap Status.effects .
                         filter ((<= 2) . Status.dur)
    match Snapshot{}   = True
    match _            = False
    foldStats          = (foldStat <$>) . group . sort
    foldStat   (x:|[]) = x
    foldStat xs@(x:|_) = x { Status.amount = sum $ Status.amount <$> xs }
    turnDecr' xs       = case mapMaybe TurnBased.decr $ toList xs of
        x:xs' -> x :| xs'
        []    -> Variant.none :| []

addStatus :: Status -> Ninja -> Ninja
addStatus st n = n { statuses = Classed.nonStack st' st' $ statuses n }
  where
    st' = st { Status.classes = filter (InvisibleTraps /=) $ Status.classes st }

-- | Passes the user's 'nId' to 'addStacks'.
addOwnStacks :: Int -> Text -> Int -> Int -> Int -> Ninja -> Ninja
addOwnStacks dur name s v i n =
    addStatus st { Status.name    = name
                 , Status.classes = Unremovable : Status.classes st
                 , Status.amount  = i
                 } n
  where
    st    = Status.new (slot n) (incr $ sync dur) $
            Character.skills (character n) !! s !! v

addOwnDefense :: Int -> Text -> Int -> Ninja -> Ninja
addOwnDefense dur name i n = n { defense = d : defense n }
  where
    d = Defense.Defense { Defense.amount = i
                        , Defense.source = slot n
                        , Defense.name   = name
                        , Defense.dur    = incr $ sync dur
                        }

clearBarrier :: Ninja -> Ninja
clearBarrier n = n { barrier = [] }

clearDefense :: Ninja -> Ninja
clearDefense n = n { defense = [] }

-- | Deletes matching 'Status'es in 'nStatuses'.
clear :: Text -> Slot -> Ninja -> Ninja
clear name source n = n { statuses = filter keep $ statuses n }
  where
    keep = not . Labeled.match name source

-- | Deletes matching 'Trap's in 'nTraps'.
clearTrap :: Text -> Slot -> Ninja -> Ninja
clearTrap name source n =
    n { traps = filter (not . Labeled.match name source) $ traps n }

-- | Resets matching 'variants'.
clearVariants :: Text -> Ninja -> Ninja
clearVariants name n = n { variants = f <$> variants n }
  where
    keep v = not (Variant.fromSkill v) || Variant.name v /= name
    f = ensure . filter keep . toList -- TODO
    ensure []     = Variant.none :| []
    ensure (x:xs) = x :| xs

-- | Deletes matching 'Channel's in 'nChannels'.
cancelChannel :: Text -> Ninja -> Ninja
cancelChannel name n = clearVariants name
                       n { channels = f $ channels n }
  where
    f = filter ((name /=) . Skill.name . Channel.skill)

-- | Removes harmful effects. Does not work if the target has 'Plague'.
cure :: (Effect -> Bool) -> Ninja -> Ninja
cure match n = n { statuses = mapMaybe cure' $ statuses n }
  where
    keep Reveal = True
    keep a      = Effect.helpful a || not (match a)
    cure' st
      | Status.source st == slot n     = Just st
      | null $ Status.effects st             = Just st
      | Unremovable ∈ Status.classes st = Just st
      | is Plague n                    = Just st
      | not $ any keep $ Status.effects st   = Nothing
      | otherwise = Just st { Status.effects = filter keep $ Status.effects st }

-- | Cures 'Bane' 'Status'es.
cureBane :: Ninja -> Ninja
cureBane n
  | is Plague n = n
  | otherwise = cure cured n { statuses = filter keep $ statuses n }
  where
    cured Afflict{} = True
    cured _         = False
    keep st         = Bane ∉ Status.classes st
                      || slot n == Status.source st

kill :: Bool -- ^ Can be prevented by 'Endure'
     -> Ninja
     -> Ninja
kill endurable n
  | endurable = setHealth 0 n
  | otherwise = n { statuses = dead : statuses n
                  , health = 0
                  }
  where
    dead = Status.dead $ slot n

-- | Decreases the duration of matching 'Status'es.
hasten :: Int -> Text -> Slot -> Ninja -> Ninja
hasten dur = prolong (-dur)

prolong :: Int -> Text -> Slot -> Ninja -> Ninja
-- | Extends the duration of matching 'Status'es.
prolong dur name src n =
    n { statuses = mapMaybe (prolong' dur name src) $ statuses n }

-- | Extends the duration of a single 'Status'.
prolong' :: Int -> Text -> Slot -> Status -> Maybe Status
prolong' dur name source st
  | Status.dur st == 0                 = Just st
  | not $ Labeled.match name source st = Just st
  | statusDur' <= 0                    = Nothing
  | otherwise                          = Just st
      { Status.dur    = statusDur'
      , Status.maxDur = max (Status.maxDur st) statusDur'
      }
              -- TODO figure out why the fuck this works
    where
      statusDur' = Status.dur st + dur'
      dur'
        | odd (Status.dur st) == even dur = dur
        | dur < 0                         = dur + 1
        | otherwise                       = dur - 1

-- | Removes all friendly effects.
purge :: Ninja -> Ninja
purge n
  | is Enrage n = n
  | otherwise         = n { statuses = doPurge <$> statuses n }
  where
    canPurge ef = Effect.helpful ef || not (Effect.sticky ef)
    doPurge st
      | Unremovable ∈ Status.classes st = st
      | otherwise = st { Status.effects = filter canPurge $ Status.effects st }

-- | Resets the duration of matching 'Status'es to their 'statusMaxDur'.
refresh :: Text -> Slot -> Ninja -> Ninja
refresh name source n = n { statuses = f <$> statuses n }
  where
    f st
      | Labeled.match name source st = st { Status.dur = Status.maxDur st }
      | otherwise                    = st

-- | Deletes one matching 'Status'.
removeStack :: Text -> Ninja -> Ninja
removeStack name n = n { statuses = f $ statuses n }
  where
    f = Status.removeMatch 1 . Labeled.match name $ slot n

-- | Replicates 'removeStack'.
removeStacks :: Text -> Int -> Slot -> Ninja -> Ninja
removeStacks name i source n = n { statuses = f $ statuses n }
  where
    f = Status.removeMatch i $ Labeled.match name source

-- | Resets 'nCharges' to four @0@s.
resetCharges :: Ninja -> Ninja
resetCharges n = n { charges = replicate 4 0 }

-- | Removes 'OnCounter' 'Trap's.
clearCounters :: Ninja -> Ninja
clearCounters n = n { traps = [trap | trap <- traps n
                                    , keep $ Trap.trigger trap] }
  where
    keep (OnCounter _) = False
    keep _             = True

kabuto :: Skill -> Ninja -> Ninja
kabuto skill n =
    n { statuses = newmode : filter (not . getMode) (statuses n)
      , variants = fromList $ (:|[]) <$> [var', var, var, var]
      , channels = toList (init nChannels') ++ [swaps (last nChannels')]
      }
  where
    nId       = slot n
    nChannels' = case channels n of
                    x:xs -> x :| xs
                    []   -> Channel.Channel
                                { Channel.root   = nId
                                , Channel.skill  = skill
                                , Channel.target = nId
                                , Channel.dur    = Skill.channel skill
                                } :| []
    sage       = " Sage"
    sLen       = length sage
    (mode, m)  = advance . maybe "" (dropEnd sLen . Status.name) .
                 find getMode $ statuses n
    var        = Variant.Variant { Variant.variant   = m
                                 , Variant.ownCd     = False
                                 , Variant.name      = ""
                                 , Variant.fromSkill = False
                                 , Variant.dur       = 0
                                 }
    var'       = var { Variant.variant = m + 1 }
    ml         = mode ++ sage
    newmode    = Status.Status { Status.amount  = 1
                               , Status.name    = ml
                               , Status.root    = nId
                               , Status.source  = nId
                               , Status.user    = nId
                               , Status.skill   = skill
                               , Status.effects = []
                               , Status.classes = [Hidden, Unremovable]
                               , Status.bombs   = []
                               , Status.maxDur  = 0
                               , Status.dur     = 0
                               }
    getMode st = Status.source st == nId
                 && sage == Text.takeEnd sLen (Status.name st)
    advance "Bloodline" = ("Genjutsu" , 2)
    advance "Genjutsu"  = ("Ninjutsu" , 3)
    advance "Ninjutsu"  = ("Taijutsu" , 4)
    advance _           = ("Bloodline", 1)
    swaps ch = ch { Channel.skill = (Channel.skill ch) { Skill.name = ml } }