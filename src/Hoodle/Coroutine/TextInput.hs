{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.TextInput 
-- Copyright   : (c) 2011-2013 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.TextInput where

import           Control.Applicative
import           Control.Lens (_1,_2,_3,view,set,(%~))
import           Control.Monad.State hiding (mapM_, forM_)
import           Control.Monad.Trans.Either
import           Data.Attoparsec
import qualified Data.ByteString.Char8 as B 
import           Data.Foldable (mapM_, forM_)
import           Data.List (sortBy)
import           Data.Maybe (catMaybes)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Data.UUID.V4 (nextRandom)
import           Graphics.Rendering.Cairo
import qualified Graphics.Rendering.Cairo.SVG as RSVG
import           Graphics.Rendering.Pango.Cairo
import           Graphics.UI.Gtk hiding (get,set)
import           System.Directory 
import           System.Exit (ExitCode(..))
import           System.FilePath 
import           System.Process (readProcessWithExitCode)
-- 
import           Control.Monad.Trans.Crtn
import           Control.Monad.Trans.Crtn.Event 
import           Control.Monad.Trans.Crtn.Queue 
import           Data.Hoodle.BBox
import           Data.Hoodle.Generic
import           Data.Hoodle.Simple 
import           Graphics.Hoodle.Render.Item 
import           Graphics.Hoodle.Render.Type.HitTest
import           Graphics.Hoodle.Render.Type.Hoodle (rHoodle2Hoodle)
import qualified Text.Hoodle.Parse.Attoparsec as PA
--
import           Hoodle.ModelAction.Layer 
import           Hoodle.ModelAction.Page
import           Hoodle.ModelAction.Select
import           Hoodle.Coroutine.Commit
import           Hoodle.Coroutine.Dialog
import           Hoodle.Coroutine.Draw 
import           Hoodle.Coroutine.Mode
import           Hoodle.Coroutine.Network
import           Hoodle.Coroutine.Select.Clipboard
import           Hoodle.Type.Canvas 
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Enum
import           Hoodle.Type.Event 
import           Hoodle.Type.HoodleState 
import           Hoodle.Util
-- 
import Prelude hiding (readFile,mapM_)


-- | single line text input : almost abandoned now
textInputDialog :: MainCoroutine (Maybe String) 
textInputDialog = do 
  doIOaction $ \_evhandler -> do 
                 dialog <- messageDialogNew Nothing [DialogModal]
                   MessageQuestion ButtonsOkCancel "text input"
                 vbox <- dialogGetUpper dialog
                 txtvw <- textViewNew
                 boxPackStart vbox txtvw PackGrow 0 
                 widgetShowAll dialog
                 res <- dialogRun dialog 
                 case res of 
                   ResponseOk -> do 
                     buf <- textViewGetBuffer txtvw 
                     (istart,iend) <- (,) <$> textBufferGetStartIter buf
                                          <*> textBufferGetEndIter buf
                     l <- textBufferGetText buf istart iend True
                     widgetDestroy dialog
                     return (UsrEv (TextInput (Just l)))
                   _ -> do 
                     widgetDestroy dialog
                     return (UsrEv (TextInput Nothing))
  let go = do r <- nextevent
              case r of 
                TextInput input -> return input 
                UpdateCanvas cid -> invalidateInBBox Nothing Efficient cid >> go 
                _ -> go 
  go 

multiLineDialog :: T.Text -> Either (ActionOrder AllEvent) AllEvent
multiLineDialog str = mkIOaction $ \evhandler -> do
    dialog <- dialogNew
    vbox <- dialogGetUpper dialog
    textbuf <- textBufferNew Nothing
    textBufferSetByteString textbuf (TE.encodeUtf8 str)
    textbuf `on` bufferChanged $ do 
        (s,e) <- (,) <$> textBufferGetStartIter textbuf <*> textBufferGetEndIter textbuf  
        contents <- textBufferGetByteString textbuf s e False
        (evhandler . UsrEv . MultiLine . MultiLineChanged) (TE.decodeUtf8 contents)
    textarea <- textViewNewWithBuffer textbuf
    vscrbar <- vScrollbarNew =<< textViewGetVadjustment textarea
    hscrbar <- hScrollbarNew =<< textViewGetHadjustment textarea 
    textarea `on` sizeRequest $ return (Requisition 500 600)
    fdesc <- fontDescriptionNew
    fontDescriptionSetFamily fdesc "Mono"
    widgetModifyFont textarea (Just fdesc)
    -- 
    table <- tableNew 2 2 False
    tableAttachDefaults table textarea 0 1 0 1
    tableAttachDefaults table vscrbar 1 2 0 1
    tableAttachDefaults table hscrbar 0 1 1 2 
    boxPackStart vbox table PackNatural 0
    -- 
    _btnOk <- dialogAddButton dialog "Ok" ResponseOk
    _btnCancel <- dialogAddButton dialog "Cancel" ResponseCancel
    _btnNetwork <- dialogAddButton dialog "Network" (ResponseUser 1)
    widgetShowAll dialog
    res <- dialogRun dialog
    widgetDestroy dialog
    case res of 
      ResponseOk -> return (UsrEv (OkCancel True))
      ResponseCancel -> return (UsrEv (OkCancel False))
      ResponseUser 1 -> return (UsrEv (NetworkProcess NetworkDialog))
      _ -> return (UsrEv (OkCancel False))

multiLineLoop :: T.Text -> MainCoroutine (Maybe T.Text)
multiLineLoop txt = do 
    r <- nextevent
    case r of 
      UpdateCanvas cid -> invalidateInBBox Nothing Efficient cid 
                          >> multiLineLoop txt
      OkCancel True -> (return . Just) txt
      OkCancel False -> return Nothing
      NetworkProcess NetworkDialog -> networkTextInput txt
      MultiLine (MultiLineChanged txt') -> multiLineLoop txt'
      _ -> multiLineLoop txt

-- | insert text 
textInput :: (Double,Double) -> T.Text -> MainCoroutine ()
textInput (x0,y0) str = do 
    modify (tempQueue %~ enqueue (multiLineDialog str))  
    multiLineLoop str >>= 
      mapM_ (\result -> deleteSelection
                        >> liftIO (makePangoTextSVG (x0,y0) result) 
                        >>= svgInsert (result,"pango"))
  
-- | insert latex
laTeXInput :: (Double,Double) -> T.Text -> MainCoroutine ()
laTeXInput (x0,y0) str = do 
    modify (tempQueue %~ enqueue (multiLineDialog str))  
    multiLineLoop str >>= 
      mapM_ (\result -> liftIO (makeLaTeXSVG (x0,y0) result) 
                        >>= \case Right r -> deleteSelection >> svgInsert (result,"latex") r
                                  Left err -> okMessageBox err >> laTeXInput (x0,y0) result
            )

-- | 
laTeXInputNetwork :: (Double,Double) -> T.Text -> MainCoroutine ()
laTeXInputNetwork (x0,y0) str =  
    networkTextInput str >>=
      mapM_ (\result -> liftIO (makeLaTeXSVG (x0,y0) result) 
                        >>= \case Right r -> deleteSelection >> svgInsert (result,"latex") r
                                  Left err -> okMessageBox err >> laTeXInput (x0,y0) result
            )


laTeXHeader :: T.Text
laTeXHeader = "\\documentclass{article}\n\
              \\\pagestyle{empty}\n\
              \\\begin{document}\n"
                                
laTeXFooter :: T.Text
laTeXFooter = "\\end{document}\n"

makeLaTeXSVG :: (Double,Double) -> T.Text 
             -> IO (Either String (B.ByteString,BBox))
makeLaTeXSVG (x0,y0) txt = do
    cdir <- getCurrentDirectory
    tdir <- getTemporaryDirectory
    tfilename <- show <$> nextRandom
    
    setCurrentDirectory tdir
    let check msg act = liftIO act >>= \(ecode,str) -> case ecode of ExitSuccess -> right () ; _ -> left (msg ++ ":" ++ str)
        
    B.writeFile (tfilename <.> "tex") (TE.encodeUtf8 txt)
    r <- runEitherT $ do 
      check "error during pdflatex" $ do 
        (ecode,ostr,estr) <- readProcessWithExitCode "xelatex" [tfilename <.> "tex"] ""
        return (ecode,ostr++estr)
      check "error during pdfcrop" $ do 
        (ecode,ostr,estr) <- readProcessWithExitCode "pdfcrop" [tfilename <.> "pdf",tfilename ++ "_crop" <.> "pdf"] ""       
        return (ecode,ostr++estr)
      check "error during pdf2svg" $ do
        (ecode,ostr,estr) <- readProcessWithExitCode "pdf2svg" [tfilename ++ "_crop" <.> "pdf",tfilename <.> "svg"] ""
        return (ecode,ostr++estr)
      bstr <- liftIO $ B.readFile (tfilename <.> "svg")
      rsvg <- liftIO $ RSVG.svgNewFromString (B.unpack bstr) 
      let (w,h) = RSVG.svgGetSize rsvg
      return (bstr,BBox (x0,y0) (x0+fromIntegral w,y0+fromIntegral h)) 
    setCurrentDirectory cdir
    return r
    

-- |
svgInsert :: (T.Text,String) -> (B.ByteString,BBox) -> MainCoroutine () 
svgInsert (txt,cmd) (svgbstr,BBox (x0,y0) (x1,y1)) = do 
    xstate <- get 
    let pgnum = view (unboxLens currentPageNum) . view currentCanvasInfo $ xstate
        hdl = getHoodle xstate 
        currpage = getPageFromGHoodleMap pgnum hdl
        currlayer = getCurrentLayer currpage
    newitem <- (liftIO . cnstrctRItem . ItemSVG) 
                 (SVG (Just (TE.encodeUtf8 txt)) (Just (B.pack cmd)) svgbstr 
                      (x0,y0) (Dim (x1-x0) (y1-y0)))  
    let otheritems = view gitems currlayer  
    let ntpg = makePageSelectMode currpage 
                 (otheritems :- (Hitted [newitem]) :- Empty)  
    modeChange ToSelectMode 
    nxstate <- get 
    thdl <- case view hoodleModeState nxstate of
              SelectState thdl' -> return thdl'
              _ -> (lift . EitherT . return . Left . Other) "svgInsert"
    nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
    put (set hoodleModeState (SelectState nthdl) nxstate)
    commit_
    invalidateAll 
  
-- |     
convertLinkFromSimpleToDocID :: Link -> IO (Maybe Link)
convertLinkFromSimpleToDocID (Link i _typ lstr txt cmd rdr pos dim) = do 
    case urlParse (B.unpack lstr) of 
      Nothing -> return Nothing
      Just (HttpUrl _url) -> return Nothing
      Just (FileUrl file) -> do 
        b <- doesFileExist file
        if b 
          then do 
            bstr <- B.readFile file
            case parseOnly PA.hoodle bstr of 
              Left _str -> return Nothing
              Right hdl -> do 
                let uuid = view hoodleID hdl
                    link = LinkDocID i uuid (B.pack file) txt cmd rdr pos dim
                return (Just link)
          else return Nothing 
convertLinkFromSimpleToDocID _ = return Nothing 

-- |   
linkInsert :: B.ByteString 
              -> (B.ByteString,FilePath)
              -> String 
              -> (B.ByteString,BBox) 
              -> MainCoroutine ()
linkInsert _typ (uuidbstr,fname) str (svgbstr,BBox (x0,y0) (x1,y1)) = do 
    xstate <- get 
    let pgnum = view (currentCanvasInfo . unboxLens currentPageNum) xstate
        hdl = getHoodle xstate 
        currpage = getPageFromGHoodleMap pgnum hdl
        currlayer = getCurrentLayer currpage
        lnk = Link uuidbstr "simple" (B.pack fname) (Just (B.pack str)) Nothing svgbstr 
                  (x0,y0) (Dim (x1-x0) (y1-y0))
    nlnk <- liftIO $ convertLinkFromSimpleToDocID lnk >>= maybe (return lnk) return
    liftIO $ print nlnk
    newitem <- (liftIO . cnstrctRItem . ItemLink) nlnk
    let otheritems = view gitems currlayer  
    let ntpg = makePageSelectMode currpage 
                 (otheritems :- (Hitted [newitem]) :- Empty)  
    modeChange ToSelectMode 
    nxstate <- get 
    thdl <- case view hoodleModeState nxstate of
              SelectState thdl' -> return thdl'
              _ -> (lift . EitherT . return . Left . Other) "linkInsert"
    nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
    let nxstate2 = set hoodleModeState (SelectState nthdl) nxstate
    put nxstate2
    invalidateAll 

-- |
makePangoTextSVG :: (Double,Double) -> T.Text -> IO (B.ByteString,BBox) 
makePangoTextSVG (xo,yo) str = do 
    let pangordr = do 
          ctxt <- cairoCreateContext Nothing 
          layout <- layoutEmpty ctxt   
          layoutSetWidth layout (Just 400)
          layoutSetWrap layout WrapAnywhere 
          layoutSetText layout (T.unpack str) -- this is gtk2hs pango limitation 
          (_,reclog) <- layoutGetExtents layout 
          let PangoRectangle x y w h = reclog 
          -- 10 is just dirty-fix
          return (layout,BBox (x,y) (x+w+10,y+h)) 
        rdr layout = do setSourceRGBA 0 0 0 1
                        updateLayout layout 
                        showLayout layout 
    (layout,(BBox (x0,y0) (x1,y1))) <- pangordr 
    tdir <- getTemporaryDirectory 
    let tfile = tdir </> "embedded.svg"
    withSVGSurface tfile (x1-x0) (y1-y0) $ \s -> renderWith s (rdr layout)
    bstr <- B.readFile tfile 
    return (bstr,BBox (xo,yo) (xo+x1-x0,yo+y1-y0)) 

-- | combine all LaTeX texts into a text file 
combineLaTeXText :: MainCoroutine ()
combineLaTeXText = do
    liftIO $ putStrLn "start combine latex file" 
    hdl <- rHoodle2Hoodle . getHoodle <$> get  
    let mlatex_components = do 
          (pgnum,pg) <- (zip ([1..] :: [Int]) . view pages) hdl  
          l <- view layers pg
          i <- view items l
          case i of 
            ItemSVG svg ->  
              case svg_command svg of
                Just "latex" -> do 
                  let (_,y) = svg_pos svg  
                  return ((pgnum,y,) <$> svg_text svg) 
                _ -> []
            _ -> []
    let cfunc :: (Ord a,Ord b,Ord c) => (a,b,c) -> (a,b,c) -> Ordering 
        cfunc x y | view _1 x > view _1 y = GT
                  | view _1 x < view _1 y = LT
                  | otherwise = if | view _2 x > view _2 y -> GT
                                   | view _2 x < view _2 y -> LT
                                   | otherwise -> EQ
    let latex_components = catMaybes  mlatex_components
        sorted = sortBy cfunc latex_components 
        resulttxt = (B.intercalate "%%%%%%%%%%%%\n\n%%%%%%%%%%\n" . map (view _3)) sorted
    mfilename <- fileChooser FileChooserActionSave Nothing
    forM_ mfilename (\filename -> liftIO (B.writeFile filename resulttxt) >> return ())