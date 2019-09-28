module Game.Model.Delay (Delay(..), new) where

import ClassyPrelude

import           Game.Model.Internal (Delay(..))
import           Game.Model.Context (Context)
import           Game.Model.Duration (Duration, incr, sync)
import qualified Game.Model.Runnable as Runnable
import           Game.Model.Runnable (RunConstraint)

new :: Context -> Duration -> RunConstraint () -> Delay
new context dur f = Delay
    { effect = Runnable.To
        { Runnable.target = context
        , Runnable.run    = f
        }
    , dur    = incr $ sync dur
    }
