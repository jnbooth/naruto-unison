module Functions 
  ( modifyAt', updateAt'
  , allied
  , unχ, χf, χNeg, χSum, χAdd, (+~), χMinus, (-~), lacks
  , filterClasses
  , living
  , removable
  , shorten
  , skillDur, skillIcon, skillRoot, skillTarget
  , zip3, zip4
  , userXP, userLevel, userRank
  , lMatch, mergeSkills
  ) where

import Prelude

import Data.String as T

import Data.Array    
import Data.Foldable         (sum)
import Data.Function.Memoize (memoize)
import Data.Maybe
import Data.Tuple            (fst)

import Operators
import Structure

modifyAt' ∷ ∀ a. Int → (a → a) → Array a → Array a
modifyAt' i f xs = fromMaybe xs $ modifyAt i f xs
updateAt' ∷ ∀ a. Int → a → Array a → Array a
updateAt' i x xs = fromMaybe xs $ updateAt i x xs

zip3 :: ∀ a b c d. (a → b → c → d) → Array a → Array b → Array c → Array d
zip3 f as bs cs = zipWith ($) (zipWith f as bs) cs
zip4 ∷ ∀ a b c d e. (a → b → c → d → e) → Array a → Array b → Array c → Array d → Array e
zip4 f as bs cs ds = zipWith ($) (zip3 f as bs cs) ds

par ∷ Int → Int
par = (_ % 2)

allSlots ∷ Array Int
allSlots = 0 .. 5
teamSlots ∷ Array Int
teamSlots = filter ((0 ≡ _) ∘ par) allSlots

allied ∷ Slot → Slot → Boolean
allied a b = par a ≡ par b

unχ ∷ Chakras → Array String
unχ (Chakras χ) = replicate χ.blood "blood"
                ⧺ replicate χ.gen   "gen"
                ⧺ replicate χ.nin   "nin"
                ⧺ replicate χ.tai   "tai"
                ⧺ replicate χ.rand  "rand"

χf ∷ (ChakraRecord → ChakraRecord) → Chakras
χf f = Chakras $ f χØ' where (Chakras χØ') = χØ

χAdd ∷ Chakras → Chakras → Chakras
χAdd (Chakras a) (Chakras b) = Chakras { blood: a.blood + b.blood 
                                       , gen:   a.gen   + b.gen
                                       , nin:   a.nin   + b.nin
                                       , tai:   a.tai   + b.tai
                                       , rand:  a.rand  + b.rand
                                       }

χMinus ∷ Chakras → Chakras → Chakras
χMinus (Chakras a) (Chakras b) = Chakras { blood: a.blood - b.blood 
                                         , gen:   a.gen   - b.gen
                                         , nin:   a.nin   - b.nin
                                         , tai:   a.tai   - b.tai
                                         , rand:  a.rand  - b.rand
                                         }

χNeg ∷ Chakras → Chakras
χNeg (Chakras {blood, gen, nin, tai, rand}) = Chakras { blood: - blood 
                                                      , gen:   - gen
                                                      , nin:   - nin
                                                      , tai:   - tai
                                                      , rand:  - rand
                                                      }

infixl 6 χAdd   as +~
infixl 6 χMinus as -~

χSum ∷ Chakras → Int
χSum (Chakras {blood, gen, nin, tai}) = blood + gen + nin + tai

lacks ∷ Chakras → Boolean
lacks (Chakras {blood, gen, nin, tai, rand}) 
    = blood < 0 ∨ gen < 0 ∨ nin < 0 ∨ tai < 0 ∨ rand < 0

living ∷ Int → Game → Int
living p (Game {gameNinjas}) = sum ∘ map health $ gameNinjas
  where health (Ninja {nId, nHealth}) = if par nId ≡ p then min 1 nHealth else 0

removable ∷ Boolean → Effect → Boolean
removable onAlly (Effect {effectSticky, effectHelpful}) 
    = not effectSticky ∧ onAlly ≠ effectHelpful

shorten ∷ String → String
shorten = T.fromCharArray ∘ map shorten' 
        ∘ filter (_ ∉ [' ','-',':','(',')','®','∘','/','?', '\'']) 
        ∘ T.toCharArray
  where shorten' 'ō' = 'o'
        shorten' 'Ō' = 'O'
        shorten' 'ū' = 'u'
        shorten' 'Ū' = 'U'
        shorten' 'ä' = 'a'
        shorten' a   = a

skillDur ∷ Skill → String
skillDur (Skill {channel}) = case channel of
    Instant     → "Instant"
    Passive     → "Instant"
    (Action 0)  → "Action"
    (Control 0) → "Control"
    (Ongoing 0) → "Ongoing"
    (Action a)  → "Action " ⧺ show a
    (Control a) → "Control " ⧺ show a
    (Ongoing a) → "Ongoing " ⧺ show a

skillIcon ∷ Skill → String
skillIcon (Skill {label, skPic}) = shorten label ⧺ if skPic then "*" else ""

skillRoot ∷ Skill → Int → Int
skillRoot (Skill {copying}) nId = case copying of
    NotCopied   → nId
    Shallow a _ → a
    Deep a    _ → a

skillTarget' ∷ Int → Skill → Array Int
skillTarget' c (Skill {start, effects})
     = if enemy ∧ ally  then allSlots
  else if enemy ∧ xally then delete c allSlots
  else if enemy         then map (_ + 1 - par c) teamSlots 
  else if ally          then map (_ + par c)     teamSlots 
  else if xally         then delete c $ map (_ + par c) teamSlots
  else                       [c]
  where targets = map fst $ start ⧺ effects
        enemy   = Enemy ∈ targets
        ally    = Ally  ∈ targets
        xally   = XAlly ∈ targets

skillTarget ∷ Int → Skill → Array Int
skillTarget = memoize skillTarget'

filterClasses' ∷ Boolean → Array String → Array String
filterClasses' hideMore = (_ ∖ filtered)
  where filtered      = hideMore ? (moreHidden ⧺ _) $ hiddenClasses
        moreHidden    = [ "Single"
                        , "Bypassing"
                        , "Uncounterable"
                        , "Unreflectable"
                        ]
        hiddenClasses = [ "NonMental"
                        , "Bloodline"
                        , "Genjutsu"
                        , "Ninjutsu"
                        , "Taijutsu"
                        , "Random"
                        , "Necromancy" 

                        , "All"
                        , "Affliction"
                        , "NonAffliction" 
                        , "NonMental"
                        , "Nonstacking" 
                        , "Multi"
                        , "Extending" 
                        , "Hidden"
                        , "Shifted" 
                        , "Unshifted"
                        , "Direct" 
                        , "BaseTrap"
                        ]

filterClasses ∷ Boolean → Array String → Array String
filterClasses = memoize filterClasses'

ranks ∷ Array String
ranks = [ "Academy Student"
         , "Genin"
         , "Chūnin"
         , "Missing-Nin"
         , "Anbu"
         , "Jōnin"
         , "Sannin"
         , "Jinchūriki"
         , "Akatsuki"
         , "Kage"
         , "Hokage"
         ]

userLevel ∷ User → Int
userLevel (User {xp}) = xp / 1000

userXP ∷ User → Int
userXP (User {xp}) = xp / 1000

userRank ∷ User → String
userRank (User {privilege, xp})
  | privilege ≡ Admin ∨ privilege ≡ Moderator = "Staff"
  | otherwise = fromMaybe "Hokage" $ ranks !! (xp / 5000)

lMatch ∷ Skill → Skill → Boolean
lMatch (Skill {label: a}) (Skill {label: b}) = a ≡ b

mergeSkills ∷ Character → Ninja → Character
mergeSkills (Character c@{characterSkills}) (Ninja {nSkills}) 
    = Character c { characterSkills = zipWith f characterSkills nSkills }
  where 
    f cSkills nSkill = map f' cSkills
      where f' cSkill | lMatch cSkill nSkill = nSkill
                      | otherwise            = cSkill