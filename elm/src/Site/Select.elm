module Site.Select exposing (Model, Msg(..), Stage(..), component)

import Browser.Dom as Dom
import Browser.Navigation as Navigation
import Dict
import Json.Decode as D
import Html as H exposing (Html)
import Html.Attributes as A
import Html.Events as E
import Html.Keyed as Keyed
import Html.Lazy exposing (lazy3)
import Http
import List.Extra as List
import List.Nonempty as Nonempty exposing (Nonempty(..))
import Maybe.Extra as Maybe
import Process
import Set exposing (Set)
import Task exposing (Task)
import Tuple exposing (first, second)
import Url

import Game.Chakra as Chakra
import Game.Game as Game
import Import.Flags exposing (Characters, Flags, characterName)
import Import.Model as Model exposing (Chakras, Character, GameInfo, ObjectiveProgress, Skill, User)
import Ports exposing (Ports)
import Site.Render as Render exposing (icon)
import Sound exposing (Sound)
import Util exposing (ListChange(..), elem, pure, showErr)


for : List a -> (a -> b) -> List b
for xs f =
    List.map f xs


wraparound : Bool -> Int -> List a -> List a
wraparound wrapping i xs =
    let
        ( before, after ) =
            List.splitAt i xs
    in
    if wrapping then
        after

    else
        after ++ before


type Previewing
    = PreviewWar
    | PreviewUser User
    | PreviewChar Character


type alias Form =
    { name       : String
    , background : String
    , condense   : Bool
    , avatar     : String
    }


type FormUpdate
    = Name String
    | Background String
    | Condense Bool
    | Avatar String


updateForm : FormUpdate -> Form -> Form
updateForm msg form =
    case msg of
        Name x ->
            { form | name = x }

        Background x ->
            { form | background = x }

        Condense x ->
            { form | condense = x }

        Avatar x ->
            { form | avatar = x }


formUrl : Form -> String
formUrl form =
    "api/update/"
        ++ form.name
        ++ "/"
        ++ (if form.condense then "True" else "False")
        ++ "/b"
        ++ form.background
        ++ "/"
        ++ Url.percentEncode form.avatar


type Stage
    = Browsing
    | Queued
    | Practicing
    | Searching


type alias Model =
    { error      : Maybe String
    , stage      : Stage
    , url        : String
    , team       : List Character
    , costs      : Chakras
    , vs         : List Character
    , unlocked   : Set String
    , user       : Maybe User
    , avatars    : List String
    , chars      : Characters
    , visibles   : Set String
    , red        : Set String
    , blue       : Set String
    , csrf       : String
    , csrfParam  : String
    , showLogin  : Bool
    , index      : Int
    , cols       : Int
    , toggled    : Maybe Character
    , previewing : Previewing
    , mission    : List ObjectiveProgress
    , alternates : List Int
    , pageSize   : Int
    , search     : String
    , condense   : Bool
    , form       : Form
    }


type Queue
    = Quick
    | Practice
    | Private


type Msg
    = Dequeue
    | DoNothing
    | Enqueue Queue
    | Fail String
    | GetMission Character
    | Page Int
    | Preview Previewing
    | Reanimate Character
    | ReceiveGame (Result Http.Error GameInfo)
    | ReceiveMission Character (Result Http.Error (List ObjectiveProgress))
    | ReceiveReanimate Character (Result Http.Error Int)
    | ReceiveUpdate (Result Http.Error ())
    | Scroll Int
    | Search
    | SetSearch String
    | SetStage Stage
    | SwitchLogin
    | Team ListChange Character
    | TryUpdate
    | Alternate Int Int
    | Vs ListChange Character
    | Untoggle
    | UpdateForm FormUpdate


teamCosts : Characters -> List Character -> Chakras
teamCosts chars team =
    team
        |> List.map chars.shortName
        >> List.filterMap (\char -> Dict.get char chars.costs)
        >> Chakra.sum


component :
    Ports Msg
    ->
        { init   : Flags -> Model
        , update : Msg -> Model -> ( Model, Cmd Msg )
        , view   : Model -> Html Msg
        }
component ports =
    let
        init : Flags -> Model
        init flags =
            { error      = Nothing
            , stage      = Browsing
            , url        = flags.url
            , team       = flags.userTeam
            , costs      = teamCosts flags.characters flags.userTeam
            , vs         = flags.userPractice
            , user       = flags.user
            , unlocked   = flags.unlocked
            , chars      = flags.characters
            , avatars    = flags.avatars
            , visibles   = flags.visibles
            , red        = flags.red
            , blue       = flags.blue
            , csrf       = flags.csrf
            , csrfParam  = flags.csrfParam
            , showLogin  = True
            , index      = 0
            , cols       = 11
            , toggled    = Nothing
            , previewing = PreviewWar
            , mission    = []
            , alternates = [ 0, 0, 0, 0 ]
            , pageSize   = 36
            , search     = ""
            , condense   =
                flags.user
                    |> Maybe.map .condense
                    >> Maybe.withDefault False
            , form       =
                case flags.user of
                    Nothing ->
                        { name       = ""
                        , background = ""
                        , condense   = False
                        , avatar     = ""
                        }

                    Just user ->
                        { name       = user.name
                        , background = Maybe.withDefault "" user.background
                        , condense   = user.condense
                        , avatar     = user.avatar
                        }
            }

        view : Model -> Html Msg
        view st =
            H.section [ A.id "charSelect" ] <|
            lazy3 (userBox st.red st.blue st.user st.csrf st.csrfParam)
                st.showLogin
                st.costs
                st.team
            :: case st.stage of
                Queued ->
                    []

                _ ->
                    let
                        topModule =
                            case st.stage of
                                Practicing ->
                                    vsBox

                                Searching ->
                                    searchBox

                                _ ->
                                    previewBox

                    in
                    [ topModule st
                    , listChars st
                    , listVs st
                    ]

        withSound : Sound -> Model -> ( Model, Cmd Msg )
        withSound sound st =
            ( st, ports.sound sound )

        update : Msg -> Model -> ( Model, Cmd Msg )
        update msg st =
            case msg of
                DoNothing ->
                    pure st

                Fail x ->
                    pure { st | error = Just x }

                SwitchLogin ->
                    pure { st | showLogin = not st.showLogin }

                Untoggle ->
                    pure { st | toggled = Nothing }

                Page x ->
                    ( st, scroll x )

                UpdateForm x ->
                    pure { st | form = updateForm x st.form }

                Scroll x ->
                    withSound Sound.Scroll <|
                        let
                            index =
                                x + st.index
                        in
                        if index < 0 then
                            let
                                rem =
                                    size st |> remainderBy -x
                                remIndex =
                                    if rem == 0 then -x else rem
                            in
                            { st
                                | index    = size st - remIndex
                                , pageSize = abs x
                            }

                        else if index >= size st then
                            { st
                                | index    = 0
                                , pageSize = abs x
                            }

                        else
                            { st
                                | index    = x + st.index
                                , pageSize = abs x
                            }

                Preview x ->
                    pure <|
                        if Maybe.isJust st.toggled then
                            st

                        else
                            { st
                                | previewing = x
                                , alternates = [ 0, 0, 0, 0 ]
                                , mission    = []
                            }

                Alternate slot i ->
                    withSound Sound.Click
                        { st | alternates = List.updateAt slot (always i) st.alternates }

                Team Add char ->
                    withSound Sound.Click <|
                        case st.toggled of
                            Nothing ->
                                { st | toggled = Just char }

                            Just toggled ->
                                if toggled /= char then
                                    { st | toggled = Just char }

                                else if locked st.unlocked char then
                                    { st | toggled = Nothing }

                                else if char |> elem st.team then
                                    { st | toggled = Nothing }

                                else if List.length st.team < Game.teamSize then
                                    let
                                        team = char :: st.team
                                    in
                                    { st
                                        | toggled = Nothing
                                        , team    = team
                                        , costs   = teamCosts st.chars team
                                    }

                                else
                                    { st | toggled = Nothing }

                Team Delete char -> case st.stage of
                    Practicing ->
                        pure st

                    _ ->
                        let
                            team = List.remove char st.team
                        in
                        withSound Sound.Cancel
                            { st
                                | team  = team
                                , costs = teamCosts st.chars team
                            }

                Vs Add char ->
                    withSound Sound.Click <|
                        if char |> elem st.vs then
                            st

                        else if List.length st.vs < Game.teamSize then
                            { st | vs = st.vs ++ [ char ] }

                        else
                            st

                Vs Delete char ->
                    withSound Sound.Cancel
                        { st | vs = List.remove char st.vs }

                TryUpdate ->
                    ( st
                    , Http.get
                        { url    = st.url ++ formUrl st.form
                        , expect = Http.expectWhatever ReceiveUpdate
                        }
                    )

                ReceiveUpdate (Ok ()) ->
                    ( st, Navigation.reload )

                ReceiveUpdate (Err (Http.BadStatus code)) ->
                    let
                        error =
                            case code of
                                500 ->
                                    "Username already taken"

                                400 ->
                                    "Name can only contain letters and numbers"

                                _ ->
                                    "Error: Code " ++ String.fromInt code
                    in
                    pure { st | error = Just error }

                ReceiveUpdate (Err err) ->
                    pure { st | error = Just <| showErr err }

                Enqueue Practice ->
                    let
                        team =
                            st.team
                                ++ st.vs
                                |> List.map characterName
                                >> String.join "/"
                                >> (++) (st.url ++ "api/practicequeue/")
                    in
                    ( st
                    , Http.get
                        { url =
                            team
                        , expect =
                            Http.expectJson ReceiveGame Model.jsonDecGameInfo
                        }
                    )

                ReceiveGame _ ->
                    pure st

                SetSearch name ->
                    pure { st | search = name }

                SetStage stage ->
                    ( { st | stage = stage, error = Nothing }
                    , case ( st.stage, stage ) of
                        ( Queued, Browsing ) ->
                            Cmd.batch
                                [ ports.websocket "cancel", ports.sound Sound.Click ]

                        _ ->
                            ports.sound Sound.Click
                    )

                Search ->
                    ( st, ports.websocket st.search )

                Enqueue Private ->
                    ( { st | stage = Queued }
                    , Cmd.batch
                        [ ports.websocket
                            << String.join "/"
                          <|
                            "private"
                                :: List.map characterName st.team
                        , Process.sleep 1000 |> Task.perform (always Search)
                        ]
                    )

                Dequeue ->
                    pure { st | stage = Browsing }

                Enqueue Quick ->
                    ( { st | stage = Queued }
                    , ports.websocket
                        << String.join "/"
                      <|
                        "quick"
                            :: List.map characterName st.team
                    )

                GetMission char ->
                    ( st
                    , Http.get
                        { url =
                            st.url ++ "api/mission/" ++ characterName char
                        , expect =
                            Http.expectJson (ReceiveMission char) <|
                            D.list Model.jsonDecObjectiveProgress
                        }
                    )

                ReceiveMission char (Ok mission) ->
                    if st.previewing == PreviewChar char then
                        pure { st | mission = mission }

                    else
                        pure st

                ReceiveMission _ (Err err) ->
                    pure { st | error = Just <| showErr err }

                Reanimate char ->
                    ( st
                    , Http.get
                        { url =
                            st.url ++ "api/reanimate/" ++ characterName char
                        , expect =
                            Http.expectJson (ReceiveReanimate char) D.int
                        }
                    )

                ReceiveReanimate char (Ok dna) ->
                    let
                        muser =
                            st.user
                    in
                    case muser of
                        Just user ->
                            withSound Sound.Win <|
                                { st
                                    | user =
                                        Just { user | dna = dna }
                                    , unlocked =
                                        Set.insert (characterName char) st.unlocked
                                }

                        Nothing ->
                            pure st

                ReceiveReanimate _ (Err err) ->
                    pure { st | error = Just <| showErr err }
    in
    { init = init, view = view, update = update }


size : Model -> Int
size st =
    if st.condense then
        List.length st.chars.groupList

    else
        List.length st.chars.list


locked : Set String -> Character -> Bool
locked set char =
    not <| Set.member (characterName char) set


belongsTo : Set String -> Character -> Bool
belongsTo war char =
    not << Set.isEmpty <| Set.intersect war char.groups


affordable : Maybe User -> Character -> Bool
affordable muser char =
    if char.price == 0 then
        False

    else
        case muser of
            Nothing ->
                False

            Just user ->
                user.dna >= char.price


userBox :
    Set String
    -> Set String
    -> Maybe User
    -> String
    -> String
    -> Bool
    -> Chakras
    -> List Character
    -> Html Msg
userBox red blue mUser csrf csrfParam showLogin costs team =
    let
        meta onClick =
            if List.length team == Game.teamSize then
                [ A.class "parchment playButton click", E.onClick onClick ]

            else
                [ A.class "parchment playButton" ]

        nav = case mUser of
            Just _ ->
                [ H.a [ A.id "mainsite"
                      , A.class "playButton parchment click blacked"
                      , A.href "/home"
                      ]
                  [ H.text "Main Site" ]
                , H.a (meta <| Enqueue Quick)
                  [ H.text "Quick" ]
                , H.a (meta <| SetStage Searching)
                  [ H.text "Private" ]
                , H.a (meta <| SetStage Practicing)
                  [ H.text "Practice" ]
                ]

            Nothing ->
                [ H.a [ A.id "mainsite"
                      , A.class "playButton parchment click blacked"
                      , A.href "/home"
                      ]
                  [ H.text "Main Site" ]
                ]

        box = case mUser of
            Just user ->
                H.div [ A.id "userBox"
                      , A.class "parchment loggedin"
                      , E.onMouseOver << Preview <| PreviewUser user
                      ]
                [ H.img [ A.class "userimg"
                        , A.src user.avatar
                        , A.alt "User avatar"
                        ] []
                , H.h4 []
                  [ H.aside [ A.class "dna" ]
                    [ H.text <| String.fromInt user.dna ]
                  , H.text user.name
                  ]
                , H.p []
                  [ H.text <| Game.rank user ]
                , H.dt [] [ H.text "Clan" ]
                , H.dd [] [ H.text <|
                    Maybe.withDefault "Clanless" user.clan
                  ]
                , H.dt [] [ H.text "Level" ]
                , H.dd [] [ H.text <|
                      String.fromInt (user.xp // 1000)
                          ++ " ("
                          ++ String.fromInt (user.xp |> remainderBy 1000)
                          ++ " XP)"
                  ]
                , H.dt [] [ H.text "Rank" ]
                , H.dd [] [ H.text "None" ]
                , H.dt [] [ H.text "Record" ]
                , H.dd [] [ Render.streak user ]
                ]

            Nothing ->
                H.div [ A.id "userBox", A.class "parchment" ]
                [ H.form
                  [ A.id <| if showLogin then "loginForm" else "registerForm"
                  , A.class "userForm"
                  , A.method "POST"
                  , A.action <|
                      "/auth/page/email/"
                          ++ (if showLogin then "login" else "register")
                  ] << List.map second <| List.filter first
                    [ ( True
                      , H.input [ A.type_ "hidden"
                                , A.name csrfParam
                                , A.value csrf
                                ] []
                      )
                    , ( True
                      , H.div []
                        [ H.input
                          [ A.class "email"
                          , A.name "email"
                          , A.type_ "email"
                          , A.required True

                          -- , A.autofocus   True
                          , A.placeholder "Email"
                          ] []
                        ]
                      )
                    , ( showLogin
                      , H.div []
                        [ H.input
                          [ A.class "password"
                          , A.name "password"
                          , A.type_ "password"
                          , A.required True
                          , A.placeholder "Password"
                          ] []
                        ]
                      )
                    , ( showLogin
                      , H.div [ A.id "controls" ]
                        [ H.button
                          [ A.class "playButton click"
                          , A.type_ "submit"
                          ]
                          [ H.text "Log in" ]
                        , H.a
                          [ A.class "click"
                          , E.onClick SwitchLogin
                          ]
                          [ H.text "Register" ]
                        ]
                      )
                    , ( not showLogin
                      , H.div [ A.id "controls" ]
                        [ H.a
                          [ A.class "click"
                          , E.onClick SwitchLogin
                          ]
                          [ H.text "Log in" ]
                        , H.button
                          [ A.class "playButton click"
                          , A.type_ "submit"
                          ]
                          [ H.text "Register" ]
                        ]
                      )
                    ]
                ]
    in
    H.header []
    [ H.nav [ A.id "playButtons" ]
      nav
    , H.div [ A.class "space" ] []
    , H.section [ A.id "teamContainer" ]
      [ Keyed.node "div"
        [ A.id "teamButtons", A.class "select" ] << for team <|
          \char ->
              let
                  isRed = char |> belongsTo red
                  isBlue = char |> belongsTo blue
              in
              ( characterName char
              , H.div [ A.class "charWrapper" ] <|
                icon char
                  "icon"
                  [ A.class "char click"
                  , E.onMouseOver << Preview <| PreviewChar char
                  , E.onClick <| Team Delete char
                  ] ::
                          if isRed && isBlue then
                              [ H.div [ A.class "redblue" ] [] ]
                          else if isRed then
                              [ H.div [ A.class "red"]  [] ]
                          else if isBlue then
                              [ H.div [ A.class "blue" ] [] ]
                          else
                              []
              )
    , H.div [ A.class "space" ] []
      , H.div [ A.id "underTeam", A.class "parchment" ] <|
        Render.chakraTotals costs
      ]
    , box
    ]


failWarning : Maybe String -> List (Html msg) -> List (Html msg)
failWarning x xs =
    case x of
        Nothing ->
            xs

        Just warning ->
            xs ++
            [ H.span [ A.id "userfail" ]
              [ H.text warning ]
            ]


vsBox : Model -> Html Msg
vsBox st =
    let
        meta =
            if List.length st.vs == Game.teamSize then
                [ A.class "parchment playButton click"
                , E.onClick <| Enqueue Practice
                ]

            else
                [ A.class "parchment playButton" ]
    in
    H.section [ A.id "vs"
              , A.classList
                [ ("parchment", True)
                , ("vsPractice", st.stage == Practicing)
                ]
              ]
      [ H.nav []
        [ H.button meta
          [ H.text "Ready" ]
        , H.button [ A.class "parchment playButton click"
                   , E.onClick <| SetStage Browsing
                   ]
          [ H.text "Cancel" ]
        ]
      , H.span []
        [ H.text "VS: " ]
      , Keyed.node "div"
        [ A.id "vsButtons", A.class "select" ] << for st.vs <|
          \char ->
              ( characterName char
              , icon char
                  "icon"
                  [ A.class "char click"
                  , E.onClick <| Vs Delete char
                  ]
              )
      ]


searchBox : Model -> Html Msg
searchBox st =
    H.section [ A.id "vs", A.class "parchment" ] <|
    failWarning st.error
    [ H.button [ A.class "parchment playButton click"
               , E.onClick <| Enqueue Private
               ]
      [ H.text "Ready" ]
    , H.button [ A.class "parchment playButton click"
               , E.onClick <| SetStage Browsing
               ]
      [ H.text "Cancel" ]
    , H.span []
      [ H.text "VS: " ]
    , H.input [ A.type_ "text"
              , A.name "search"
              , A.value st.search
              , E.onInput SetSearch
              ] []
    ]


listWar : String -> Set String -> Html msg
listWar class war =
    war
        |> Set.toList
        >> List.map (H.text >> List.singleton >> H.p [])
        >> H.div [ A.class class ]


previewBox : Model -> Html Msg
previewBox st =
    case st.previewing of
        PreviewWar ->
            H.article [ A.class "parchment war" ]
            [ H.section []
              [ listWar "red" st.red
              , H.h1 [] [ H.text "Today's War" ]
              , listWar "blue" st.blue
              ]
            , H.p []
              [ H.text "Choose a side! Make a full team from one side and earn bonus DNA for defeating full teams from the other side."]
            ]

        PreviewUser _ ->
            H.article [ A.class "parchment" ]
            [ H.div [ A.id "accountSettings" ]
              [ H.p [] <|
                failWarning st.error
                [ H.label []
                  [ H.text "Name" ]
                , H.input [ A.type_ "text"
                          , A.name "name"
                          , A.value st.form.name
                          , E.onInput <| UpdateForm << Name
                          ] []
                ]
              , H.p []
                [ H.label []
                  [ H.text "Background" ]
                , H.input [ A.type_ "text"
                          , A.name "background"
                          , A.value st.form.background
                          , E.onInput <| UpdateForm << Background
                          ] []
                ]
              , H.p []
                [ H.input [ A.type_ "checkbox"
                          , A.name "condense"
                          , A.checked st.form.condense
                          , E.onInput <|
                              always <<
                              UpdateForm <<
                              Condense <|
                              not st.form.condense
                          ] []
                , H.label []
                  [ H.text "Show only the first version of each character in the selection grid" ]
                ]
              , H.p []
                [ H.span []
                  [ H.text "Avatars" ]
                ]
              , H.section
                [ A.id "avatars" ] << for st.avatars <|
                  \avatar ->
                      if st.form.avatar == avatar then
                          H.img [ A.src avatar, A.class "noclick"] []

                      else
                          H.img [ A.src avatar
                                , A.class "click"
                                , E.onClick << UpdateForm <| Avatar avatar
                                ] []
              , H.button [ A.id "updateButton"
                         , A.class "click", E.onClick TryUpdate
                         ]
                [ H.text "Update" ]
              , H.a [ A.href "auth/logout" ]
                [ H.button [ A.id "logoutButton", A.class "click" ]
                  [ H.text "Log out" ]
                ]
              ]
            ]

        PreviewChar char ->
            H.article [ A.class "parchment" ] <|
            [ Keyed.node "aside"
              [] <|
              if not st.condense then
                  []

              else case Dict.get (st.chars.shortName char) st.chars.groupDict of
                  Nothing ->
                      []

                  Just (Nonempty _ []) ->
                      []

                  Just (Nonempty x xs) -> for (x :: xs) <| \char_ ->
                      ( characterName char_
                      , icon char_ "icon" <|
                          if locked st.unlocked char_ then
                              [ A.classList
                                [ ( "on", char == char_ )
                                , ( "noclick locked char", True )
                                ]
                              , E.onMouseOver << Preview <| PreviewChar char_
                              ]

                          else if
                              List.member char_ <|
                                  case st.stage of
                                      Practicing ->
                                          st.vs

                                      _ ->
                                          st.team
                          then
                              [ A.classList
                                [ ( "on", char == char_ )
                                , ( "noclick disabled char", True )
                                ]
                              , E.onMouseOver << Preview <| PreviewChar char_
                              ]

                          else
                              [ A.classList
                                [ ( "on", char == char_ )
                                , ( "click char", True )
                                ]
                              , E.onMouseOver << Preview <| PreviewChar char_
                              , E.onClick <| Team Add char_
                              ]
                      )
          , H.h3 [] <|
            [ icon char "icon" [ A.class "char" ]
            , if not <| locked st.unlocked char then
                H.aside [] []

              else if char.price > 0 then
                H.aside [ A.class "dna" ] <|
                    if affordable st.user char then
                        [ H.button [E.onClick <| Reanimate char]
                          [H.text "Reanimate"]
                        , H.text <| String.fromInt char.price
                        ]

                    else
                        [ H.text <| String.fromInt char.price ]

              else
                        H.aside [ A.class "locked" ] <|
                        if List.isEmpty st.mission then
                            [ H.button [ E.onClick <| GetMission char ]
                              [ H.text "Show Mission" ]
                            ]

                        else
                            [ H.button
                              [ E.onClick << Preview <| PreviewChar char ]
                              [ H.text "Hide Mission" ]
                            ]
                    ]
                        ++ Render.name char
                , H.p [] <|
                  if List.isEmpty st.mission then
                      Render.desc char.bio

                  else
                      [ H.section []
                        [ H.ul [] <| List.map previewObjective st.mission ]
                      ]
          ] ++
          List.map3 (previewSkill st.visibles char)
          (List.range 0 10) -- doesn't matter, not the limiting factor
          char.skills
          st.alternates


previewObjective : ObjectiveProgress -> Html Msg
previewObjective x =
    H.li [] <|
    List.concat
        [ case x.character of
              Nothing ->
                  []

              Just char ->
                  [ H.text <| "As " ++ char ++ ": " ]

        , Render.desc x.desc

        , if x.progress < x.goal then
              [ H.span [A.class "incomplete"]
                [ H.text
                    <| " "
                    ++ String.fromInt x.progress
                    ++ "/"
                    ++ String.fromInt x.goal
                ]
              ]

          else
              [ H.span [A.class "complete"]
                [ H.text
                    <| " "
                    ++ String.fromInt x.goal
                    ++ "/"
                    ++ String.fromInt x.goal
                ]
              ]
        ]

previewSkill : Set String -> Character -> Int -> List Skill -> Int -> Html Msg
previewSkill visibles char slot skills i =
    case List.getAt i skills of
        Nothing ->
            H.section [] []

        Just skill ->
            let
                findDifferent xs x =
                    List.findIndices (\y -> y.name /= x.name) xs

                vPrev =
                    List.getAt i skills
                        |> Maybe.andThen
                            (List.last << findDifferent (List.take i skills))
                        >> Maybe.map
                            (\v ->
                                H.a [ A.class "prevSkill click"
                                    , E.onClick <| Alternate slot v
                                    ]
                                    []
                            )

                vNext =
                    List.getAt i skills
                        |> Maybe.andThen
                            (List.head << findDifferent (List.drop i skills))
                        >> Maybe.map
                            (\v ->
                                H.a [ A.class "nextSkill click"
                                    , E.onClick << Alternate slot <| v + i
                                    ]
                                    []
                            )
            in
            H.section []
            [ H.div [] <|
              Maybe.values
              [ Just <| icon char skill.name [ A.class "char" ]
              , vPrev
              , vNext
              ]
            , H.h4 [] <|
              H.text skill.name
              :: Render.chakras skill.cost ++
              [ Render.classes False <| Set.intersect visibles skill.classes ]
            , H.p [] <<
              (++) (Render.desc skill.desc) <<
              List.map
              (H.span [ A.class "extra" ] << List.singleton << H.text << second)
              <| List.filter first
              [ ( skill.charges > 1
                , String.fromInt skill.charges ++ " charges."
                )
              , ( skill.charges == 1
                , String.fromInt skill.charges ++ " charge."
                )
              , ( skill.cooldown > 0
                , "CD: " ++ String.fromInt ((skill.cooldown + 1) // 2)
                )
              ]
            ]


listChars : Model -> Html Msg
listChars st =
    let
        wrapping =
            st.index + st.pageSize >= size st
        wrap =
            wraparound wrapping st.index

        displays =
            if st.condense then
                st.chars.groupList
                    |> wrap
                    >> List.map Nonempty.head

            else
                st.chars.list
                    |> wrap

        charClass char =
            -- god I wish this language had pattern guards
            let
                select =
                    case st.toggled of
                        Nothing ->
                            ""

                        Just toggled ->
                            if toggled == char then
                                "selected"

                            else
                                "deselected"

                lock =
                    if locked st.unlocked char then
                        if affordable st.user char then
                            "locked buy"

                        else
                            "locked"

                    else if
                        List.member char st.team
                    then
                        "disabled"

                    else
                        ""
            in
            if String.isEmpty select && String.isEmpty lock then
                "char click"

            else
                String.join " " [ "char", select, lock ]

        displayChar char =
            let
                isRed = char |> belongsTo st.red
                isBlue = char |> belongsTo st.blue
            in
            ( characterName char
            , H.div [ A.class "charWrapper" ] <|
                icon char "icon"
                [ E.onMouseOver << Preview <| PreviewChar char
                , E.onClick <| Team Add char
                , A.class <| charClass char
                ] ::
                    if isRed && isBlue then
                        [ H.div [ A.class "redblue" ] [] ]
                    else if isRed then
                        [ H.div [ A.class "red"]  [] ]
                    else if isBlue then
                        [ H.div [ A.class "blue" ] [] ]
                    else
                        []
            )

        baseAttrs =
            [ A.class "chars", A.class "parchment", A.id "forTeam" ]

        attrs =
            if st.stage == Practicing then
                A.style "display" "none" :: baseAttrs
            else
                baseAttrs

    in
    H.section attrs
    [ Render.scroll "prevPage"
      (if st.index == 0 then "close" else "left") <| Page -1
    , Render.scroll "nextPage"
      (if wrapping then "close" else "right") <| Page 1
    , Keyed.node "div" [ A.id "teamScroll"
                       , A.class "charScroll"
                       , E.onMouseLeave Untoggle
                       ] <|
      List.map displayChar displays
    ]


listVs : Model -> Html Msg
listVs st =
    let
        charClass char =
            if List.member char st.vs then
                "char disabled"

            else
                "char click"

        displayChar char =
            ( characterName char
            , H.div [ A.class "charWrapper", A.title char.name ]
                [ icon char "icon"
                  [ E.onClick <| Vs Add char
                  , A.class <| charClass char
                  ]
                ]
            )

        baseAttrs =
            [ A.class "chars", A.class "parchment full", A.id "forVs" ]

        attrs =
            if st.stage /= Practicing then
                A.style "display" "none" :: baseAttrs
            else
                baseAttrs
    in
    H.section attrs
    [ Keyed.node "div" [ A.class "charScroll"
                       , E.onMouseLeave Untoggle
                       ] <|
      List.map displayChar st.chars.list
    ]


calcSize : Dom.Viewport -> Int
calcSize dom =
    floor (dom.viewport.width / 68) * floor (dom.viewport.height / 64)


scrollTask : Int -> Task Dom.Error Int
scrollTask signum =
    Dom.getViewportOf "teamScroll"
        |> Task.map ((*) signum << calcSize)


scrollCase : Result Dom.Error Int -> Msg
scrollCase x =
    case x of
        Ok val ->
            Scroll val

        Err (Dom.NotFound e) ->
            Fail <| "Not found: " ++ e


scroll : Int -> Cmd Msg
scroll =
    scrollTask
        >> Task.attempt scrollCase
