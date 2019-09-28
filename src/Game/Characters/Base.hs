{-# OPTIONS_HADDOCK hide #-}

module Game.Characters.Base
  ( module Import
  , invuln
  , user, target, userHas, targetHas
  , userStacks, targetStacks, userDefense
  , channeling, invulnerable
  , self, allies, enemies, everyone
  , baseVariant
  , bonusIf, numAffected, numDeadAllies
  ) where

import ClassyPrelude as Import hiding (swap)

import Game.Model.Character as Import (Character(..), Category)
import Game.Model.Chakra as Import (Chakra(..), Chakras)
import Game.Model.Channel as Import (Channeling(..))
import Game.Model.Copy as Import (Copying(..))
import Game.Model.Class as Import (Class(..))
import Game.Model.Effect as Import (Amount(..), Constructor(..), Effect(..))
import Game.Model.Ninja as Import (Ninja(health, slot), alive, hasDefense, hasOwn, isChanneling, numActive, numAnyStacks, numHelpful)
import Game.Model.Requirement as Import (Requirement(..))
import Game.Model.Runnable as Import (Runnable(To))
import Game.Model.Skill as Import (Target(..))
import Game.Model.Status as Import (Bomb(..))
import Game.Model.Trigger as Import (Trigger(..))
import Game.Action.Chakra as Import
import Game.Action.Combat as Import
import Game.Action.Channel as Import
import Game.Action.Skill as Import
import Game.Action.Status as Import
import Game.Action.Trap as Import
import Game.Engine.Skills as Import
import Game.Engine.Ninjas as Import (addOwnStacks, addOwnDefense)

import Data.Enum.Set.Class (EnumSet)

import qualified Class.Play as P
import           Class.Play (MonadPlay)
import qualified Game.Model.Context as Context
import qualified Game.Model.Ninja as Ninja
import qualified Game.Model.Skill as Skill
import           Game.Model.Skill (Skill)
import qualified Game.Model.Slot as Slot
import           Game.Model.Slot (Slot)
import qualified Game.Engine.Effects as Effects

invuln :: Text -> Text -> EnumSet Class -> Skill
invuln skillName userName classes = Skill.new
    { Skill.name      = skillName
    , Skill.desc      = userName ++ " becomes invulnerable for 1 turn."
    , Skill.classes   = classes
    , Skill.cooldown  = 4
    , Skill.effects   = [To Self $ apply 1 [Invulnerable All]]
    }

self :: ∀ m a. MonadPlay m => m a -> m a
self = P.with Context.reflect

targetWithUser :: ∀ m. MonadPlay m => (Slot -> [Slot]) -> m () -> m ()
targetWithUser targeter f = do
    targets <- targeter <$> P.user
    P.withTargets targets f

-- | Directly applies an effect to all allies, both living and dead,
-- ignoring invulnerabilities and traps.
allies :: ∀ m. MonadPlay m => m () -> m ()
allies = targetWithUser Slot.allies

-- | Directly applies an effect to all enemies, both living and dead,
-- ignoring invulnerabilities and traps.
enemies :: ∀ m. MonadPlay m => m () -> m ()
enemies = targetWithUser Slot.enemies

-- | Directly applies an effect to all other Ninjas, both living and dead,
-- ignoring invulnerabilities and traps.
everyone :: ∀ m. MonadPlay m => m () -> m ()
everyone = targetWithUser (`delete` Slot.all)

baseVariant :: Text
baseVariant = mempty

bonusIf :: ∀ m. MonadPlay m => Int -> m Bool -> m Int
bonusIf amount condition = do
    succeed <- condition
    return if succeed then amount else 0

user :: ∀ m a. MonadPlay m => (Ninja -> a) -> m a
user f = f <$> P.nUser

target :: ∀ m a. MonadPlay m => (Ninja -> a) -> m a
target f = f <$> P.nTarget

userHas :: ∀ m. MonadPlay m => Text -> m Bool
userHas name = Ninja.hasOwn name <$> P.nUser

targetHas :: ∀ m. MonadPlay m => Text -> m Bool
targetHas name = Ninja.has name <$> P.user <*> P.nTarget

userStacks :: ∀ m. MonadPlay m => Text -> m Int
userStacks name = Ninja.numStacks name <$> P.user <*> P.nUser

targetStacks :: ∀ m. MonadPlay m => Text -> m Int
targetStacks name = Ninja.numStacks name <$> P.user <*> P.nTarget

userDefense :: ∀ m. MonadPlay m => Text -> m Int
userDefense name = defense <$> P.nUser
  where
    defense n = Ninja.defenseAmount name (slot n) n

channeling :: ∀ m. MonadPlay m => Text -> m Bool
channeling name = Ninja.isChanneling name <$> P.nUser

invulnerable :: Ninja -> Bool
invulnerable n = not . null $ Effects.invulnerable n

filterOthers :: ∀ m. MonadPlay m => (Ninja -> Bool) -> m Int
filterOthers match = length . filter match <$> (P.allies =<< P.user)

numAffected :: ∀ m. MonadPlay m => Text -> m Int
numAffected name = filterOthers =<< Ninja.has name <$> P.user

numDeadAllies :: ∀ m. MonadPlay m => m Int
numDeadAllies = filterOthers $ not . alive