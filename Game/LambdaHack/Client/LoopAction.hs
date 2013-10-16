{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
-- | The main loop of the client, processing human and computer player
-- moves turn by turn.
module Game.LambdaHack.Client.LoopAction (loopAI, loopUI) where

import Control.Monad
import qualified Data.Text as T

import Game.LambdaHack.Client.Action
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.AtomicCmd
import Game.LambdaHack.Common.ClientCmd
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Utils.Assert

initCli :: MonadClient m => (State -> m ()) -> m Bool
initCli putSt = do
  -- Warning: state and client state are invalid here, e.g., sdungeon
  -- and sper are empty.
  cops <- getsState scops
  restored <- restoreGame
  case restored of
    Just (s, cli) -> do  -- Restore the game.
      let sCops = updateCOps (const cops) s
      putSt sCops
      putClient cli
      return True
    Nothing ->  -- First visit ever, use the initial state.
      return False

loopAI :: (MonadClientReadServer CmdClientAI m)
       => (CmdClientAI -> m ()) -> m ()
loopAI cmdClientAISem = do
  side <- getsClient sside
  restored <- initCli $ \s -> cmdClientAISem $ CmdAtomicAI $ ResumeServerA s
  cmd1 <- readServer
  case (restored, cmd1) of
    (True, CmdAtomicAI ResumeA{}) -> return ()
    (True, CmdAtomicAI RestartA{}) -> return ()  -- server savefile faulty
    (False, CmdAtomicAI ResumeA{}) ->
      error $ T.unpack $ "Savefile of client " <> showT side <> " not usable. Please remove all savefiles manually and restart. "
    (False, CmdAtomicAI RestartA{}) -> return ()
    _ -> assert `failure` (side, restored, cmd1)
  cmdClientAISem cmd1
  -- State and client state now valid.
  debugPrint $ "AI client" <+> showT side <+> "started."
  loop
  debugPrint $ "AI client" <+> showT side <+> "stopped."
 where
  loop = do
    cmd <- readServer
    cmdClientAISem cmd
    quit <- getsClient squit
    unless quit loop

loopUI :: (MonadClientUI m, MonadClientReadServer CmdClientUI m)
       => (CmdClientUI -> m ()) -> m ()
loopUI cmdClientUISem = do
  Kind.COps{corule} <- getsState scops
  let title = rtitle $ Kind.stdRuleset corule
  side <- getsClient sside
  restored <- initCli $ \s -> cmdClientUISem $ CmdAtomicUI $ ResumeServerA s
  cmd1 <- readServer
  case (restored, cmd1) of
    (True, CmdAtomicUI ResumeA{}) -> do
      let msg = "Welcome back to" <+> title <> "."
      cmdClientUISem cmd1
      msgAdd msg
    (True, CmdAtomicUI RestartA{}) -> do
      cmdClientUISem cmd1
      msgAdd "Starting a new game (and ignoring an old client savefile)."
    (False, CmdAtomicUI ResumeA{}) ->
      error $ T.unpack $ "Savefile of client " <> showT side <> " not usable. Please remove all savefiles manually and restart. "
    (False, CmdAtomicUI RestartA{}) -> do
      let msg = "Welcome to" <+> title <> "!"
      cmdClientUISem cmd1
      msgAdd msg
    _ -> assert `failure` (side, restored, cmd1)
  -- State and client state now valid.
  debugPrint $ "UI client" <+> showT side <+> "started."
  loop
  debugPrint $ "UI client" <+> showT side <+> "stopped."
 where
  loop = do
    cmd <- readServer
    cmdClientUISem cmd
    quit <- getsClient squit
    unless quit loop
