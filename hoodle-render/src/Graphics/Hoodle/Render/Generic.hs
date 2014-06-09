{-# LANGUAGE FlexibleInstances, FlexibleContexts, TypeFamilies #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Graphics.Hoodle.Render.Generic 
-- Copyright   : (c) 2011-2014 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Graphics.Hoodle.Render.Generic where

import Control.Applicative
import Control.Lens
import Control.Monad hiding (mapM_,mapM)
import Data.Foldable
import Data.Traversable 
import qualified Graphics.Rendering.Cairo as Cairo
-- from hoodle-platform
import Data.Hoodle.BBox
import Data.Hoodle.Generic
import Data.Hoodle.Simple
-- from this package 
import Graphics.Hoodle.Render
import Graphics.Hoodle.Render.Debug
import Graphics.Hoodle.Render.Type 
-- 
import Prelude hiding (mapM_,mapM)

-- | temporary util
passarg :: (Monad m) => (a -> m ()) -> a -> m a
passarg f a = f a >> return a


-- | 
class Renderable a where 
  cairoRender :: RenderCache -> a -> Cairo.Render a
                 
-- | 
instance Renderable (Background,Dimension) where
  cairoRender = const (passarg renderBkg) 

-- | 
instance Renderable Stroke where 
  cairoRender = const (passarg renderStrk)

-- | 
instance Renderable (BBoxed Stroke) where
  cairoRender =const (passarg (renderStrk . bbxed_content))
  
-- | 
instance Renderable RLayer where
  cairoRender cache = renderRLayer_InBBox cache Nothing 
  
-- | 
class RenderOptionable a where   
  type RenderOption a :: *
  cairoRenderOption :: RenderOption a -> RenderCache -> a -> Cairo.Render a

-- | 
instance RenderOptionable (Background,Dimension) where
  type RenderOption (Background,Dimension) = ()
  cairoRenderOption () = cairoRender 

-- | 
instance RenderOptionable Stroke where
  type RenderOption Stroke = () 
  cairoRenderOption () = cairoRender
  
-- | 
data StrokeBBoxOption = DrawFull | DrawBoxOnly 

-- | 
instance RenderOptionable (BBoxed Stroke) where
  type RenderOption (BBoxed Stroke) = StrokeBBoxOption
  cairoRenderOption DrawFull = cairoRender 
  cairoRenderOption DrawBoxOnly = const (passarg renderStrkBBx_BBoxOnly)
  
-- | 
instance RenderOptionable (RBackground,Dimension) where 
  type RenderOption (RBackground,Dimension) = RBkgOpt 
  cairoRenderOption RBkgDrawPDF cache = renderRBkg cache
  cairoRenderOption RBkgDrawWhite cache = passarg (renderRBkg_Dummy cache)
  cairoRenderOption RBkgDrawBuffer cache = renderRBkg_Buf cache 
  cairoRenderOption (RBkgDrawPDFInBBox mbbox) cache = renderRBkg_InBBox cache mbbox 

-- | 
instance RenderOptionable RLayer where
  type RenderOption RLayer = StrokeBBoxOption 
  cairoRenderOption DrawFull cache = cairoRender cache
  cairoRenderOption DrawBoxOnly cache = passarg (renderRLayer_BBoxOnly cache)

-- | 
instance RenderOptionable (InBBox RLayer) where
  type RenderOption (InBBox RLayer) = InBBoxOption
  cairoRenderOption (InBBoxOption mbbox) cache (InBBox lyr) = 
    InBBox <$> renderRLayer_InBBoxBuf cache mbbox lyr
    
-- |
cairoOptionPage :: ( RenderOptionable (b,Dimension)
                   , RenderOptionable a
                   , Foldable s) => 
                   (RenderOption (b,Dimension), RenderOption a) 
                   -> RenderCache
                   -> GPage b s a 
                   -> Cairo.Render (GPage b s a)
cairoOptionPage (optb,opta) cache p = do 
    cairoRenderOption optb cache (view gbackground p, view gdimension p)
    mapM_ (cairoRenderOption opta cache) (view glayers p)
    return p 
  
-- | 
instance ( RenderOptionable (b,Dimension)
         , RenderOptionable a
         , Foldable s) =>
         RenderOptionable (GPage b s a) where
  type RenderOption (GPage b s a) = (RenderOption (b,Dimension), RenderOption a)
  cairoRenderOption = cairoOptionPage
            
-- | 
instance RenderOptionable (InBBox RPage) where
  type RenderOption (InBBox RPage) = InBBoxOption 
  cairoRenderOption (InBBoxOption mbbox) cache (InBBox page) = do 
    cairoRenderOption (RBkgDrawPDFInBBox mbbox) cache (view gbackground page, view gdimension page) 
    let lyrs = view glayers page
    nlyrs <- mapM (liftM unInBBox . cairoRenderOption (InBBoxOption mbbox) cache . InBBox ) lyrs
    let npage = set glayers nlyrs page
    return (InBBox npage) 

-- | 
instance RenderOptionable (InBBoxBkgBuf RPage) where
  type RenderOption (InBBoxBkgBuf RPage) = InBBoxOption 
  cairoRenderOption (InBBoxOption mbbox) cache (InBBoxBkgBuf page) = do 
    cairoRenderOption (RBkgDrawPDFInBBox mbbox) cache (view gbackground page, view gdimension page) 
    let lyrs = view glayers page
    nlyrs <- mapM (renderRLayer_InBBox cache mbbox) lyrs
    let npage = set glayers nlyrs page
    return (InBBoxBkgBuf npage) 



