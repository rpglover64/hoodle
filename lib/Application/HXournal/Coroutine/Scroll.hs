
-----------------------------------------------------------------------------
-- |
-- Module      : Application.HXournal.Coroutine.Scroll 
-- Copyright   : (c) 2011, 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
module Application.HXournal.Coroutine.Scroll where

import Application.HXournal.Type.Event 
import Application.HXournal.Type.Coroutine
import Application.HXournal.Type.Canvas
import Application.HXournal.Type.XournalState
import Application.HXournal.Coroutine.Draw
import qualified Data.IntMap as IM
import Control.Monad.Trans
import qualified Control.Monad.State as St
import Control.Monad.Coroutine.SuspensionFunctors
import Control.Category
import Data.Label
import Prelude hiding ((.), id)

vscrollStart :: CanvasId -> MainCoroutine () -- Iteratee MyEvent XournalStateIO () 
vscrollStart cid = vscrollMove cid 
        
vscrollMove :: CanvasId -> MainCoroutine () -- Iteratee MyEvent XournalStateIO () 
vscrollMove cid = do    
  ev <- await 
  case ev of
    VScrollBarMoved _cid' v -> do 
      xstate <- lift St.get 
      let cinfoMap = get canvasInfoMap xstate
          maybeCvs = IM.lookup cid cinfoMap 
      case maybeCvs of 
        Nothing -> return ()
        Just cvsInfo -> do 
          let vm_orig = get (viewPortOrigin.viewInfo) cvsInfo
          let cvsInfo' = set (viewPortOrigin.viewInfo) (fst vm_orig,v)
                         $ cvsInfo 
              cinfoMap' = IM.adjust (const cvsInfo') cid cinfoMap  
              xstate' = set canvasInfoMap cinfoMap' 
                        . set currentCanvas cid
                        $ xstate
          lift . St.put $ xstate'
          -- invalidateBBoxOnly cid
          invalidateWithBuf cid 
          vscrollMove cid 
    VScrollBarEnd cid' _v -> do 
      invalidate cid' 
      return ()
    _ -> return ()       
    
    
