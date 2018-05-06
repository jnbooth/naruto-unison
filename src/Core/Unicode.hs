-- | Various unicode synonyms for basic functions.
module Core.Unicode
  ( module Import
  , (§), (∘), (—), (÷), (٪), (⩀), (☩), (◁), (▷), (◇), (∈), (∉), ø
  ) where

import Prelude.Unicode       as Import hiding ((¬), (÷), (∘), (∈), (∉)) 
import Control.Monad.Unicode as Import
import Data.List.Unicode     as Import hiding ((∈), (∉))

-- import Data.Foldable (elem, notElem)
import Data.List     (intersect)
import Data.Sequence (Seq, (><), (|>), (<|), empty)
import Data.Text     (append, Text)

-- | 'elem'
infix 4 ∈
(∈) ∷ (Foldable a, Eq b) ⇒ b → a b → Bool
(∈) = elem
{-# INLINE (∈) #-}

-- | 'notElem'
infix 4 ∉
(∉) ∷ (Foldable a, Eq b) ⇒ b → a b → Bool
(∉) = notElem
{-# INLINE (∉) #-}

-- | '$' with right-fixity 1
infixr 2 §
(§) ∷ (a → b) → a → b
(§) = ($)
{-# INLINE (§) #-}

-- | '.' with right-fixity 7
infixr 7 ∘ 
(∘) ∷ (b → g) → (a → b) → a → g
(∘) = (.)
{-# INLINE (∘) #-}

-- | A subtraction symbol that respects sections, like 'subtract'.
(—) ∷ Num a ⇒ a → a → a
(—) = (-) 

-- | 'quot'
infixl 7 ÷
(÷) ∷ Integral a ⇒ a → a → a
(÷) = quot
{-# INLINE (÷) #-}

-- | 'mod'
infix 7 ٪
(٪) ∷ Integral a ⇒ a → a → a
(٪) = mod
{-# INLINE (٪) #-}

-- | 'not' . 'null' . 'intersect'
infix 6 ⩀
(⩀) ∷ Eq a ⇒ [a] → [a] → Bool
(⩀) a b = not ∘ null $ intersect a b

-- | 'append'
(☩) ∷ Text → Text → Text
(☩) = append
{-# INLINE (☩) #-}

-- | 'errorEmptyList'
ø ∷ Seq a
ø = empty

infixr 5 ◇
(◇) ∷ Seq a → Seq a → Seq a
(◇) = (><)
{-# INLINE (◇) #-}

infixr 5 ◁
(◁) ∷ a → Seq a → Seq a
(◁) = (<|)
{-# INLINE (◁) #-}

infixl 5 ▷
(▷) ∷ Seq a → a → Seq a
(▷) = (|>)
{-# INLINE (▷) #-}