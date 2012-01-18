
-----------------------------------------------------------------------------
-- |
-- Module      : Application.HXournal.Coroutine.Highlighter 
-- Copyright   : (c) 2011, 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
module Application.HXournal.Coroutine.Highlighter where

import Application.HXournal.Device 
import Application.HXournal.Type.Event
import Application.HXournal.Type.Coroutine
import Application.HXournal.Type.XournalState
import Control.Monad.Trans

highlighterStart :: PointerCoord -> MainCoroutine () -- Iteratee MyEvent XournalStateIO ()
highlighterStart _pcoord = do 
  liftIO $ putStrLn "highlighter started"

