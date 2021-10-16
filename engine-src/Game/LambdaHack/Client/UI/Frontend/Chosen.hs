-- | Re-export the operations of the chosen raw frontend
-- (determined at compile time with cabal flags).
module Game.LambdaHack.Client.UI.Frontend.Chosen
  ( startup, frontendName
  ) where

import Prelude ()

#ifdef USE_BROWSER
import Game.LambdaHack.Client.UI.Frontend.Dom
#else
import Game.LambdaHack.Client.UI.Frontend.Sdl
#endif
