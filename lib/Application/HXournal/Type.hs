{-# LANGUAGE OverloadedStrings #-}

module Application.HXournal.Type where

import Application.HXournal.Device
import Control.Monad.Coroutine 
import Control.Monad.Coroutine.SuspensionFunctors
import Data.Functor.Identity (Identity(..))
import Control.Monad.State
import Data.Sequence

import Data.IORef

import Text.Xournal.Type
import Text.Xournal.Predefined 

import Graphics.UI.Gtk

import Data.Maybe
import qualified Data.Map as M
import qualified Data.ByteString.Char8 as B

type Trampoline m x = Coroutine Identity m x 
type Generator a m x = Coroutine (Yield a) m x
type Iteratee a m x = Coroutine (Await a) m x

type XournalStateIO = StateT XournalState IO 

data PenDrawing = PenDrawing { penDrawingPoints :: Seq (Double,Double)
                             } 
                  
data PageMode = Continous | OnePage
              deriving (Show,Eq) 

data ZoomMode = Original | FitWidth | Zoom Double 
              deriving (Show,Eq)

data ViewMode = ViewMode { vm_pgmode :: PageMode 
                         , vm_zmmode :: ZoomMode 
                         , vm_viewportOrigin :: (Double,Double) 
                         , vm_pagedim :: (Double,Double)
                         } 
              deriving (Show,Eq)

data PenType = PenWork | HighlighterWork | EraserWork 
             deriving (Show,Eq)
                      
data PenColor = ColorBlack
              | ColorBlue 
              | ColorRed
              | ColorGreen
              | ColorGray
              | ColorLightBlue 
              | ColorLightGreen 
              | ColorMagenta
              | ColorOrange
              | ColorYellow
              | ColorWhite
              | ColorRGBA Double Double Double Double 
              deriving (Show,Eq,Ord)
      
data PenMode = PenMode { pm_pentype :: PenType 
                       , pm_penwidth :: Double 
                       , pm_pencolor :: PenColor
                       } 
             deriving (Show)

penColorNameMap :: M.Map PenColor B.ByteString                        
penColorNameMap = M.fromList [ (ColorBlack, "black")
                             , (ColorBlue , "blue")
                             , (ColorRed  , "red") 
                             , (ColorGreen, "green")
                             , (ColorGray,  "gray")
                             , (ColorLightBlue, "lightblue")
                             , (ColorLightGreen, "lightgreen")
                             , (ColorMagenta, "magenta")
                             , (ColorOrange, "orange")
                             , (ColorYellow, "yellow")
                             , (ColorWhite, "white") ]

penColorRGBAmap :: M.Map PenColor (Double,Double,Double,Double)
penColorRGBAmap = M.fromList $ map (\x->(fst x,fromJust (M.lookup (snd x) predefined_pencolor))) 
                             $ M.toList penColorNameMap 

convertPenColorToRGBA :: PenColor -> (Double,Double,Double,Double)
convertPenColorToRGBA (ColorRGBA r g b a) = (r,g,b,a)
convertPenColorToRGBA c = fromJust (M.lookup c penColorRGBAmap)


data XournalState = 
  XournalState 
  { xoj :: Xournal 
  , darea :: DrawingArea
  , currpage :: Int 
  , currpendrawing :: PenDrawing 
  , callback :: MyEvent -> IO ()
  , device :: DeviceList 
  , viewMode :: ViewMode
  , penMode :: PenMode 
  , hscrolladj :: Adjustment
  , vscrolladj :: Adjustment 
  } 
                      

data MyEvent = Initialized
             | CanvasConfigure Double Double 
             | ButtonLeft 
             | ButtonRight 
             | ButtonRefresh 
             | ButtonQuit 
             | UpdateCanvas
             | MenuNew 
             | MenuAnnotatePDF
             | MenuOpen 
             | MenuSave
             | MenuSaveAs
             | MenuRecentDocument
             | MenuPrint 
             | MenuExport 
             | MenuQuit 
             | MenuUndo 
             | MenuRedo 
             | MenuCut 
             | MenuCopy 
             | MenuPaste 
             | MenuDelete
             | MenuFullScreen 
             | MenuZoom 
             | MenuZoomIn
             | MenuZoomOut 
             | MenuNormalSize
             | MenuPageWidth
             | MenuSetZoom
             | MenuFirstPage
             | MenuPreviousPage 
             | MenuNextPage 
             | MenuLastPage 
             | MenuShowLayer
             | MenuHideLayer
             | MenuNewPageBefore
             | MenuNewPageAfter 
             | MenuNewPageAtEnd 
             | MenuDeletePage
             | MenuNewLayer
             | MenuDeleteLayer
             | MenuPaperSize
             | MenuPaperColor
             | MenuPaperStyle 
             | MenuApplyToAllPages 
             | MenuLoadBackground
             | MenuBackgroundScreenshot 
             | MenuDefaultPaper
             | MenuSetAsDefaultPaper
             | MenuShapeRecognizer
             | MenuRuler
             | MenuSelectRegion
             | MenuSelectRectangle
             | MenuVerticalSpace
             | MenuHandTool
             | MenuPenOptions
             | MenuEraserOptions 
             | MenuHighlighterOptions
             | MenuTextFont
             | MenuDefaultPen 
             | MenuDefaultEraser 
             | MenuDefaultHighlighter
             | MenuDefaultText 
             | MenuSetAsDefaultOption
             | MenuUseXInput
             | MenuDiscardCoreEvents 
             | MenuEraserTip 
             | MenuPressureSensitivity
             | MenuPageHighlight
             | MenuMultiplePageView
             | MenuMultiplePages
             | MenuButton2Mapping
             | MenuButton3Mapping 
             | MenuAntialiasedBitmaps
             | MenuProgressiveBackgrounds
             | MenuPrintPaperRuling 
             | MenuLeftHandedScrollbar
             | MenuShortenMenus
             | MenuAutoSavePreferences
             | MenuSavePreferences
             | MenuAbout
             | MenuDefault
             | PenDown PointerCoord
             | PenMove PointerCoord
             | PenUp   PointerCoord 
             | HScrollBarMoved Double
             | VScrollBarMoved Double 
             deriving (Show,Eq,Ord)


emptyXournalState :: XournalState
emptyXournalState = 
  XournalState 
  { xoj = emptyXournal
  , darea = undefined
  , currpage = 0 
  , currpendrawing = PenDrawing empty 
  , callback = undefined 
  , device = undefined
  , viewMode = ViewMode OnePage Original (0,0) undefined 
  , penMode = PenMode PenWork predefined_medium ColorBlack
  , hscrolladj = undefined             
  , vscrolladj = undefined 
  } 
  
  