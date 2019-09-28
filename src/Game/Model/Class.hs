module Game.Model.Class
  ( Class(..)
  , name, lower
  , visible, visibles
  ) where

import ClassyPrelude

import           Data.Aeson (ToJSON(..), Value)
import qualified Data.Enum.Memo as Enum
import           Data.Enum.Set.Class (AsEnumSet(..))
import           Text.Blaze (ToMarkup(..))

import Core.Util (mapFromKeyed)
import Class.Display (Display(..))

-- | Qualifiers of 'Model.Skill.Skill's and 'Model.Status.Status'es.
data Class
    -- Kind
    = Chakra
    | Mental
    | Physical
    | Summon
    -- Distance
    | Melee
    | Ranged
    -- Effects
    | Bypassing
    | Invisible
    | Soulbound
    -- Tags
    | Bane
    | Necromancy
    -- Prevention
    | Uncounterable
    | Unreflectable
    | Unremovable
    -- Fake (Hidden)
    | All
    | Hidden
    | Affliction
    | NonAffliction
    | NonMental
    | Resource -- ^ Display stacks separately
    | Direct
    -- Limits (Hidden)
    | Nonstacking
    | Extending
    -- Chakra (Hidden)
    | Bloodline
    | Genjutsu
    | Ninjutsu
    | Taijutsu
    | Random
    deriving (Bounded, Enum, Eq, Ord, Show, Read)

instance AsEnumSet Class where
    type EnumSetRep Class = Word64

instance ToJSON Class where
    toJSON = toJSON . name

instance ToMarkup Class where
    toMarkup = toMarkup . name

instance Hashable Class where
    hashWithSalt salt = hashWithSalt salt . fromEnum

instance Display Class where
    display = Enum.memoize $ display . name

visible :: Class -> Bool
visible = (< All)

visibles :: Value
visibles = toJSON . mapFromKeyed @(Map _ _) (name, const True) $
           filter visible [minBound, maxBound]
{-# NOINLINE visibles #-}

name :: Class -> Text
name Nonstacking    = "Non-stacking"
name NonAffliction  = "Non-affliction"
name NonMental      = "Non-mental"
name x              = tshow x

lower :: Class -> TextBuilder
lower = Enum.memoize $ display . toLower . name