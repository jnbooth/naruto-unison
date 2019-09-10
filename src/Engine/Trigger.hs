-- | Processing of 'Effect's that change an action as it occurs.
module Engine.Trigger
  ( redirect
  , reflect
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
import           Model.Effect (Effect(..))
import qualified Model.Ninja as Ninja
import           Model.Ninja (Ninja, is)
import           Model.Slot (Slot)
import qualified Model.Skill as Skill
import           Model.Skill (Skill)
import qualified Model.Status as Status
import           Model.Status (Status)
import qualified Model.Trap as Trap
import           Model.Trap (Trap, Trigger(..))
import qualified Engine.Ninjas as Ninjas
import qualified Engine.Traps as Traps


-- | Trigger a 'Reflect'.
reflect :: EnumSet Class -> Ninja -> Ninja -> Maybe Ninja
reflect classes n nt
  | [Mental, Unreflectable] `intersects` classes              = Nothing
  | any ((ReflectAll ∈) . Status.effects) $ Ninja.statuses nt = Just nt
  | any ((OnReflectAll ==) . Trap.trigger) $ Ninja.traps n    = Just nt
  | otherwise = Ninjas.drop (Reflect ==) nt

-- | Trigger a 'SnareTrap'.
snareTrap :: Skill -> Ninja -> Maybe (Ninja, Int)
snareTrap skill n = [(n', a) | (n', SnareTrap _ a, _) <- Ninjas.take match n]
  where
    match (SnareTrap cla _) = cla ∈ Skill.classes skill
    match _                 = False

reflectable :: ([Effect] -> Bool) -> EnumSet Class -> Ninja -> Maybe Status
reflectable matches classes n
  | Unreflectable ∈ classes = Nothing
  | otherwise               = find (matches . Status.effects) $ Ninja.statuses n

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
    let res
          | n `is` Plague = mempty
          | otherwise     = Traps.getOf slot OnRes n
    if | Ninja.health n > 0 -> return ()
       | null res           -> do
            P.modify slot $ Ninjas.clearTraps OnDeath
            traverse_ P.launch $ Traps.getOf slot OnDeath n
            P.modifyAll unres
       | otherwise          -> do
            P.modify slot $ Ninjas.setHealth 1 . Ninjas.clearTraps OnRes
            traverse_ P.launch res
  where
    unres n = n
        { Ninja.statuses = [st | st <- Ninja.statuses n
                               , slot /= Status.user st
                                 || Soulbound ∉ Status.classes st]
        , Ninja.traps    = [trap | trap <- Ninja.traps n
                                 , slot /= Trap.user trap
                                   || Soulbound ∉ Trap.classes trap]
        }

getCounters :: ∀ m. (MonadPlay m, MonadRandom m)
           => (Trap -> Maybe Class) -> Slot -> EnumSet Class -> Ninja -> [m ()]
getCounters f from classes n = mapMaybe g $ Ninja.traps n
  where
    g tr = case f tr of
        Just cla | cla ∈ classes -> Just . P.launch $ Traps.run from tr
        _                        -> Nothing

userCounters :: ∀ m. (MonadPlay m, MonadRandom m)
             => Slot -> EnumSet Class -> Ninja -> [m ()]
userCounters = getCounters f
  where
    f tr = case Trap.trigger tr of
        Countered cla -> Just cla
        _             -> Nothing

userUncounter :: EnumSet Class -> Ninja -> Ninja
userUncounter classes n =
    n { Ninja.traps = filter (keep . Trap.trigger) $ Ninja.traps n }
  where
    keep (Countered cla) = cla ∉ classes
    keep _               = True

targetCounters :: ∀ m. (MonadPlay m, MonadRandom m)
             => Slot -> EnumSet Class -> Ninja -> [m ()]
targetCounters = getCounters f
  where
    f tr = case Trap.trigger tr of
        CounterAll cla -> Just cla
        Counter cla    -> Just cla
        _              -> Nothing

targetUncounter :: EnumSet Class -> Ninja -> Ninja
targetUncounter classes n =
    n { Ninja.traps = filter (keep . Trap.trigger) $ Ninja.traps n }
  where
    keep (Counter cla) = cla ∉ classes
    keep _             = True
