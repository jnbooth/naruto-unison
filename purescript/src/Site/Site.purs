module Site
  ( Query(..)
  , Stage(..)
  , component
  , module Site.Common
  ) where

import Prelude
import Data.Array ((:), intercalate, reverse)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))
import Data.UUID (UUID)
import Effect.Class (liftEffect)
import Effect.Aff.Class (class MonadAff, liftAff)
import Halogen (Component, ParentHTML, ParentDSL, parentComponent, get, modify_, raise, query)
import Halogen.HTML as H
import Halogen.HTML (HTML)
import Halogen.HTML.Events as E

import FFI.Import (bg, getJson, unJson)
import FFI.Progress (progress)
import FFI.Sound (Sound(..), sound)
import Model.Game (Game, GameInfo(..))
import Site.Common (ArrayOp(..), ChildQuery(..), HTMLQ, JSONFail(..), PlayQuery(..), Previewing(..), QueueType(..), SelectQuery(..), SocketMsg(..), Viewable(..), _a, _b, _c, _extra, _i, _minor, _span, _src, _style, _txt)

import Site.CharacterSelect as Select
import Site.Play as Play

data Query a
    = HandleQueue Select.Message a
    | HandleGame Play.Message a
    | ReceiveMsg SocketMsg UUID a
    | EndTurn UUID a

data ChildSlot
    = SelectSlot
    | PlaySlot

derive instance eqChildSlot  :: Eq ChildSlot
derive instance ordChildSlot :: Ord ChildSlot

data Stage
    = Waiting
    | Queueing
    | Playing
    | Practicing

derive instance eqStage :: Eq Stage

type State = { stage    :: Stage
             , gameInfo :: Either String GameInfo
             , turn     :: Maybe UUID
             }

component :: ∀ m. MonadAff m => Component HTML Query Unit SocketMsg m
component = parentComponent
    { initialState: const initialState
    , render
    , eval
    , receiver: const Nothing
    }
  where
  initialState :: State
  initialState = { stage:    Waiting
                 , gameInfo: Left ""
                 , turn:     Nothing
                 }

  render :: State -> ParentHTML Query ChildQuery ChildSlot m
  render st = contents $ case st.gameInfo of
    Right gameInfo' ->
      [ H.img [_i "bg", _src bg ]
      , H.slot PlaySlot (Play.comp (st.stage == Practicing) gameInfo')
                        unit (E.input HandleGame)
      ]
    Left error ->
      [ H.span [_c "error"] [H.text error]
      , H.slot SelectSlot Select.comp unit (E.input HandleQueue)
      ]
    where
      contents
        | st.stage == Queueing =
            H.div [_i "contents", _c "queueing"] <<<
            (H.aside [_i "searching"] [H.img [_src "/img/spin.gif"]]:_)
        | otherwise = H.div [_i "contents"]

  eval :: Query ~> ParentDSL State Query ChildQuery ChildSlot SocketMsg m
  eval = case _ of
      HandleQueue (Select.Queued Practice team) a -> a <$ do
          let teamList = intercalate "/" <<< reverse $ show <$> team
          game <- liftAff <<< getJson $ "/api/practicequeue/" <> teamList
          modify_ _{ gameInfo = game
                   , stage = Practicing
                   }
          liftEffect $ progress (Milliseconds 0.0) 1 1
          sound SFXStartFirst
      HandleQueue (Select.Queued Quick team) a -> a <$ do
          let teamList = intercalate "/" <<< reverse $ show <$> team
          modify_ _{ stage = Queueing }
          sound SFXApplySkill
          raise $ SocketMsg teamList
      HandleQueue (Select.UpdateMsg msg) a -> a <$ raise msg
      HandleQueue _ a -> pure a
      HandleGame (Play.Finish _) a -> a <$
        modify_ _{ gameInfo = Left ""
                 , turn = Nothing
                 , stage = Waiting
                 }
      HandleGame (Play.ActMsg msg) a -> a <$ do
          modify_ _{ turn = Nothing }
          raise msg
      ReceiveMsg (SocketMsg msg) uuid a -> do
          {stage} <- get
          case stage of
              Queueing -> do
                  let result = unJson msg
                  modify_ _{ gameInfo = result
                          , stage    = Playing
                          }
                  case result of
                      Left _ -> pure a
                      Right (GameInfo {player}) -> do
                          liftEffect $
                           progress (Milliseconds 60000.0) (1 - player) player
                          sound SFXStartFirst
                          pure a
              Playing -> do
                  modify_ _{ turn = Just uuid }
                  case unJson msg of
                      Left _ -> pure a
                      Right (game :: Game) -> do
                          _ <- query PlaySlot $ QueryPlay (ReceiveGame game) a
                          pure a
              _ -> pure a
      EndTurn uuid a -> a <$ do
        {turn} <- get
        when (turn == Just uuid) <<< raise $ SocketMsg "0,0,0,0/0,0,0,0"