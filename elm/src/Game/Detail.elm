module Game.Detail exposing
    ( Detail
    , allied
    , channel
    , copy
    , get
    )

import List.Extra as List
import List.Nonempty exposing (Nonempty(..))
import Set exposing (Set)

import Game.Game as Game
import Import.Model exposing (Channel, Channeling(..), Copy, Effect, Ninja, Status, Trap)
import Util exposing (groupBy)


type alias Detail =
    { name    : String
    , desc    : String
    , classes : Set String
    , dur     : Int
    , source  : Int
    , user    : Int
    , effects : List Effect
    , trap    : Bool
    , amount  : Int
    }


get : Ninja -> List Detail
get n =
    let
        statuses =
            List.map status n.statuses

        reduce ((Nonempty x xs) as xxs) =
            case List.find (eq x) statuses of
                Just y  -> Nonempty y <| x :: xs
                Nothing -> xxs

        traps =
            n.traps
                |> List.map trap
                >> groupBy eq
                >> List.map (reduce >> concat)

        stats =
            statuses
                |> List.filter (\x -> not <| List.any (eq x) traps)
                >> List.concatMap unfold

        ( self, others ) =
            stats ++ traps
                |> List.partition (.user >> (==) n.slot)
    in
    others ++ self


eq : Detail -> Detail -> Bool
eq x y =
    x.dur == y.dur
    && x.name == y.name
    && ignoreClasses x.classes == ignoreClasses y.classes


ignoredClasses : Set String
ignoredClasses =
    Set.fromList
        [ "Bypassing"
        , "Non-stacking"
        , "Soulbound"
        , "Uncounterable"
        , "Unreflectable"
        , "Unremovable"
        ]


ignoreClasses : Set String -> Set String
ignoreClasses xs =
    Set.diff xs ignoredClasses


allied : Int -> Detail -> Bool
allied user x =
    (user < Game.teamSize) == (x.user < Game.teamSize)


concat : Nonempty Detail -> Detail
concat (Nonempty x xs) =
    let
        xxs =
            x :: xs
    in
    { x
        | effects =
            xxs
                |> List.concatMap .effects
                >> List.uniqueBy .desc
                >> List.filter .visible
        , trap =
            xxs
                |> List.any .trap
        , amount =
            xxs
                |> List.filter (not << .trap)
                >> List.map .amount
                >> List.sum
    }


unfold : Detail -> List Detail
unfold x =
    if x.amount <= 1 || not (Set.member "Resource" x.classes) then
        [ x ]

    else
        List.repeat x.amount { x | amount = 1 }


channel : Int -> Channel -> Detail
channel user x =
    { name    = x.skill.name
    , desc    = x.skill.desc
    , classes = x.skill.classes
    , dur     = Game.dur x
    , source  = x.skill.owner
    , user    = user
    , effects = []
    , trap    =
        case x.dur of
            Control _ -> True
            _         -> False
    , amount = 1
    }


copy : Copy -> Detail
copy x =
    { name    = x.skill.name
    , desc    = x.skill.desc
    , classes = x.skill.classes
    , dur     = x.dur
    , source  = x.skill.owner
    , user    = x.skill.owner
    , effects = []
    , trap    = False
    , amount  = 1
    }


status : Status -> Detail
status x =
    { name    = x.name
    , desc    = x.skill.desc
    , classes = x.classes
    , dur     = x.dur
    , source  = x.skill.owner
    , user    = x.user
    , effects = List.uniqueBy .desc x.effects
    , trap    = False
    , amount  = x.amount
    }


trap : Trap -> Detail
trap x =
    let
        effects =
            { desc    = x.trigger
            , helpful = False
            , sticky  = True
            , trap    = True
            , visible = True
            , slot    = Nothing
            }
    in
    { name    = x.name
    , desc    = x.skill.desc
    , classes = x.classes
    , dur     = x.dur
    , source  = x.skill.owner
    , user    = x.user
    , effects = [ effects ]
    , trap    = True
    , amount  = 1
    }
