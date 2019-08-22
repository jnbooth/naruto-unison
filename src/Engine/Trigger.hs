-- | Processing of 'Effect's that change an action as it occurs.
module Engine.Trigger
  ( counter1
  , parry
  , redirect
  , reflect
  , replace
  , death
  , snareTrap
  , swap

  , targetCounters, targetUncounter
  , userCounters, userUncounter
  ) where

import ClassyPrelude hiding (swap)

import Data.Enum.Set.Class (EnumSet)

import           Core.Util ((∈), (∉), intersects)
import qualified Class.Play as P
import           Class.Play (MonadGame, MonadPlay)
import           Class.Random (MonadRandom)
import           Model.Class (Class(..))
import           Model.Duration (Duration)
import           Model.Effect (Effect(..))
import qualified Model.Channel as Channel
import qualified Model.Context as Context
import           Model.Context (Context)
import qualified Model.Ninja as Ninja
import           Model.Ninja (Ninja, is)
import qualified Model.Runnable as Runnable
import           Model.Runnable (Runnable)
import           Model.Slot (Slot)
import qualified Model.Skill as Skill
import           Model.Skill (Skill)
import qualified Model.Status as Status
import           Model.Status (Status)
import qualified Model.Trap as Trap
import           Model.Trap (Trigger(..))
import qualified Engine.Adjust as Adjust
import qualified Engine.Traps as Traps

-- | Trigger a 'Replace'.
-- Returns ('Status.user', 'Status.name', 'Effects.replaceTo', 'Effects.replaceDuration').
replace :: EnumSet Class -> Ninja -> Bool -> [(Slot, Text, Int, Duration)]
replace classes n harm = mapMaybe ifCopy allStatuses
  where
    allStatuses = filter (any matches . Status.effects) $ Ninja.statuses n
    matches (Replace _ cla _ noharm) = (harm || noharm) && cla ∈ classes
    matches _                        = False
    ifCopy st = [(Status.user st, Status.name st, to, dur)
                  | Replace dur _ to _ <- find matches $ Status.effects st]

-- | Trigger a 'Counter'.
counter1 :: EnumSet Class
        -> Ninja -- ^ User
        -> Ninja -- ^ Target
        -> Maybe (Ninja, Ninja, Maybe (Runnable Context))
        -- ^ (User without counter, target without counter, counter effect)
counter1 classes n nt =
    do
        guard $ Uncounterable ∉ classes
        trap <- find ((OnCounterAll ==) . Trap.trigger) $ Ninja.traps n
        return (n, nt, Just $ launchTrap trap)
    <|> do
        guard . any (any counterAll . Status.effects) $ Ninja.statuses nt
        return (n, nt, Nothing)
        {-}
    <|> do
        i <- Seq.findIndexL (onCounter . Trap.trigger) $ Ninja.traps n
        let n' = n { Ninja.traps = Seq.deleteAt i $ Ninja.traps n }
        return (n', nt, launchTrap <$> Seq.lookup i (Ninja.traps n))
        -}
    <|> do
        nt' <- Ninja.drop counterOne nt
        return (n, nt', Nothing)
  where
    launchTrap trap             = Trap.effect trap 0
    matchClass cla              = cla == Uncounterable
                                  || cla ∈ classes && Uncounterable ∉ classes
    counterAll (CounterAll cla) = matchClass cla
    counterAll _                = False
    onCounter (OnCounter cla)   = matchClass cla
    onCounter _                 = False
    counterOne (Counter cla)    = matchClass cla
    counterOne _                = False

-- | Trigger a 'Parry'.
parry :: Skill -> Ninja -> Maybe (Ninja, Status, Runnable ())
parry skill n =
    [(n', st, a) | st <- find (any matchN . Status.effects) $ Ninja.statuses n
                 , ParryAll _ a <- find matchN $ Status.effects st]
    <|> [(n'', st, a) | (n'', Parry _ a, st) <- Ninja.take match n]
  where
    classes = Skill.classes skill
    n'      = n -- { Ninja.parrying = skill : Ninja.parrying n }
    matchN (ParryAll Uncounterable _) = True
    matchN (ParryAll cla _)           = cla ∈ classes
                                        && Uncounterable ∉ classes
    matchN _                          = False
    match (Parry Uncounterable _)     = True
    match (Parry cla _)               = cla ∈ classes
                                        && Uncounterable ∉ classes
    match _ = False

-- | Trigger a 'Reflect'.
reflect :: EnumSet Class -> Ninja -> Ninja -> Maybe Ninja
reflect classes n nt
  | [Mental, Unreflectable] `intersects` classes              = Nothing
  | any ((ReflectAll ∈) . Status.effects) $ Ninja.statuses nt = Just nt
  | any ((OnReflectAll ==) . Trap.trigger) $ Ninja.traps n    = Just nt
  | otherwise = Ninja.drop (Reflect ==) nt

-- | Trigger a 'SnareTrap'.
snareTrap :: Skill -> Ninja -> Maybe (Ninja, Int)
snareTrap skill n = [(n', a) | (n', SnareTrap _ a, _) <- Ninja.take match n]
  where
    match (SnareTrap cla _) = cla ∈ Skill.classes skill
    match _                 = False

reflectable :: ([Effect] -> Bool) -> EnumSet Class -> Ninja -> Maybe Status
reflectable matches classes
  | Unreflectable ∈ classes = const Nothing
  | otherwise               = find (matches . Status.effects) . Ninja.statuses

-- | Trigger a 'Redirect'.
redirect :: EnumSet Class -> Ninja -> Maybe Slot
redirect classes n = listToMaybe [slot | Redirect cla slot <- Ninja.effects n
                                       , cla ∈ classes || cla == Uncounterable]

-- | Trigger a 'Swap'.
swap :: EnumSet Class -> Ninja -> Maybe Status
swap classes = reflectable (any match) classes
  where
    match (Swap cla) = cla ∈ classes
    match _          = False


-- | If the 'Ninja.health' of a 'Ninja' reaches 0,
-- they are either resurrected by triggering 'OnRes'
-- or they die and trigger 'OnDeath'.
-- If they die, their 'Soulbound' effects are canceled.
death :: ∀ m. (MonadGame m, MonadRandom m) => Slot -> m ()
death slot = do
    n <- P.ninja slot
    let die = Traps.getOf slot [OnDeath] n
        res
          | n `is` Plague = mempty
          | otherwise     = Traps.getOf slot [OnRes] n
    if | Ninja.health n > 0 -> return ()
       | not $ null res     -> do
            P.modify slot \nt ->
                nt { Ninja.health = 1
                   , Ninja.traps  = filter ((OnRes /=) . Trap.trigger) $
                                    Ninja.traps nt
                   }
            trigger res
       | otherwise -> do
            P.modify slot \nt ->
                nt { Ninja.traps = filter ((OnDeath /=) . Trap.trigger) $
                                  Ninja.traps nt }
            trigger die
            P.modifyAll unres
  where
    trigger = traverse_ $ P.launch . Runnable.retarget \ctx ->
                  ctx { Context.user = slot }
    unres n = n
        { Ninja.statuses = [st | st <- Ninja.statuses n
                               , slot /= Status.user st
                                 && slot /= Status.user st
                                 || Soulbound ∉ Status.classes st]
        , Ninja.traps    = [trap | trap <- Ninja.traps n
                                 , slot /= Trap.user trap
                                   || Soulbound ∉ Trap.classes trap]
        , Ninja.channels = filter ((slot /=) . Channel.target) $
                           Ninja.channels n
        }

userCounters :: ∀ m. (MonadPlay m, MonadRandom m)
             => EnumSet Class -> Ninja -> [m ()]
userCounters classes = mapMaybe f . Ninja.traps
  where
    f tr = case Trap.trigger tr of
        OnCounterAll                  -> Just add
        OnCounter cla | cla ∈ classes -> Just add
        _                             -> Nothing
      where
        add = P.launch $ Traps.run (Trap.user tr) tr

{-}
userCounters :: ∀ m. (MonadPlay m, MonadRandom m)
             => EnumSet Class -> Ninja -> [m ()]
userCounters classes = elems . foldr acc mempty . Ninja.traps
  where
    acc tr = case Trap.trigger tr of
        OnCounterAll                  -> add
        OnCounter cla | cla ∈ classes -> add
        _                             -> id
      where
        add = insertMap (Trap.name tr) (P.launch $ Traps.run (Trap.user tr) tr)
-}
userUncounter :: EnumSet Class -> Ninja -> Ninja
userUncounter classes n =
    n { Ninja.traps = filter (keep . Trap.trigger) $ Ninja.traps n }
  where
    keep (OnCounter cla) = cla ∉ classes
    keep _               = True

targetCounters :: ∀ m. (MonadPlay m, MonadRandom m)
               => EnumSet Class -> Ninja -> [m ()]
targetCounters classes = mapMaybe f . Ninja.effects
  where
    f (CounterAll cla)   | cla ∈ classes = Just $ return ()
    f (Counter cla)      | cla ∈ classes = Just $ return ()
    f (ParryAll cla run) | cla ∈ classes = Just $ Runnable.run run
    f (Parry cla run)    | cla ∈ classes = Just $ Runnable.run run
    f _                                  = Nothing

targetUncounter :: EnumSet Class -> Ninja -> Ninja
targetUncounter classes n =
    Adjust.effects n { Ninja.statuses = mapMaybe f $ Ninja.statuses n }
  where
    uncounter (Counter cla) = cla ∈ classes
    uncounter (Parry cla _) = cla ∈ classes
    uncounter _             = False
    f st = case partition uncounter $ Status.effects st of
        ([], _)   -> Just st
        (_,  [])  -> Nothing
        (_,  efs) -> Just st { Status.effects = efs }
