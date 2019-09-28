module Game.Model.Ninja
  ( Ninja(..), new
  , skillSize
  , alive, minHealth
  , is, isChanneling
  , has, hasOwn, hasDefense, hasTrap
  , numActive, numStacks, numAnyStacks, numHelpful
  , defenseAmount
  ) where

import ClassyPrelude

import           Core.Util ((∈), (∉))
import qualified Class.Parity as Parity
import qualified Class.Labeled as Labeled
import           Game.Model.Internal (Ninja(..))
import qualified Game.Model.Channel as Channel
import           Game.Model.Character (Character)
import           Game.Model.Class (Class(..))
import qualified Game.Model.Defense as Defense
import qualified Game.Model.Effect as Effect
import           Game.Model.Effect (Effect(..))
import qualified Game.Model.Skill as Skill
import           Game.Model.Slot (Slot)
import qualified Game.Model.Status as Status
import qualified Game.Model.Variant as Variant

skillSize :: Int
skillSize = 4

-- | Constructs a @Ninja@ with starting values from a character and an index.
new :: Slot -> Character -> Ninja
new slot c = Ninja { slot      = slot
                   , health    = 100
                   , character = c
                   , defense   = mempty
                   , barrier   = mempty
                   , statuses  = mempty
                   , charges   = replicate skillSize 0
                   , cooldowns = replicate skillSize mempty
                   , variants  = replicate skillSize $ Variant.none :| []
                   , copies    = replicate skillSize Nothing
                   , channels  = mempty
                   , newChans  = mempty
                   , traps     = mempty
                   , delays    = mempty
                   , face      = mempty
                   , lastSkill = Nothing
                   , triggers  = mempty
                   , effects   = mempty
                   , acted     = False
                   }

alive :: Ninja -> Bool
alive n = health n > 0

is :: Ninja -> Effect -> Bool
is n ef = ef ∈ effects n

isChanneling :: Text -- ^ 'Skill.name'.
             -> Ninja -> Bool
isChanneling name n = any ((name ==) . Skill.name . Channel.skill) $ channels n

has :: Text -- ^ 'Status.name'.
    -> Slot -- ^ 'Status.user'.
    -> Ninja -> Bool
has name user n = any (Labeled.match name user) $ statuses n

hasDefense :: Text -- ^ 'Defense.name'.
           -> Slot -- ^ 'Defense.user'.
           -> Ninja -> Bool
hasDefense name user n = any (Labeled.match name user) $ defense n

defenseAmount :: Text -- ^ 'Defense.name'.
              -> Slot -- ^ 'Defense.user'.
              -> Ninja -> Int
defenseAmount name user n =
    sum [ Defense.amount d | d <- defense n
                           , Defense.user d == user
                           , Defense.name d == name
                           ]

hasTrap :: Text -- ^ 'Trap.name'.
        -> Slot -- ^ 'Trap.user'.
        -> Ninja -- ^ 'traps' owner.
        -> Bool
hasTrap name user n = any (Labeled.match name user) $ traps n

hasOwn :: Text -> Ninja -> Bool
hasOwn name n = has name (slot n) n
                || isChanneling name n
                || hasDefense name (slot n) n

-- | Number of stacks of matching self-applied 'statuses'.
numActive :: Text -- ^ 'Status.name'.
          -> Ninja -> Int
numActive name n
  | stacks > 0    = stacks
  | hasOwn name n = 1
  | otherwise     = 0
  where
    stacks = numStacks name (slot n) n

-- | Number of stacks of matching 'statuses'.
numStacks :: Text -- ^ 'Status.name'.
          -> Slot -- ^ 'Status.user'.
          -> Ninja -> Int
numStacks name user n =
    sum $ Status.amount <$> filter (Labeled.match name user) (statuses n)

-- | Number of stacks of 'statuses' from any source.
numAnyStacks :: Text -- ^ 'Status.name'.
             -> Ninja -> Int
numAnyStacks name n =
    sum $ Status.amount <$> filter ((name ==) . Status.name) (statuses n)

-- | Counts all 'Effect.helpful' effects in 'statuses' from allies.
-- Does not include self-applied or 'Hidden' 'Status'es.
-- Each status counts for @(number of helpful effects) * (Status.amount)@.
numHelpful :: Ninja -> Int
numHelpful n = sum [Status.amount st | st <- statuses n
                                     , let user = Status.user st
                                     , slot n /= user
                                     , Parity.allied n user
                                     , Hidden ∉ Status.classes st
                                     , ef <- Status.effects st
                                     , Effect.helpful ef]

-- | @1@ if affected by 'Endure', otherwise @0@.
minHealth :: Ninja -> Int
minHealth n
  | n `is` Endure = 1
  | otherwise     = 0