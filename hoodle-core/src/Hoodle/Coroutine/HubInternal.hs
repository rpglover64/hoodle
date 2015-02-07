{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.HubInternal
-- Copyright   : (c) 2014, 2015 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.HubInternal where

import           Control.Applicative
import           Control.Concurrent
import qualified Control.Exception as E
import           Control.Lens (view,set,_2)
import           Control.Monad.IO.Class
import           Control.Monad.State
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.Resource
import           Data.Aeson as AE
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Digest.Pure.MD5 (md5)
import qualified Data.Foldable as F
import qualified Data.HashMap.Strict as H
import qualified Data.IntMap as IM
import           Data.IORef
import           Data.List (find)
import           Data.Monoid ((<>))
import qualified Data.Text as T (Text,pack,unpack)
import qualified Data.Text.Encoding as TE (encodeUtf8,decodeUtf8)
import           Data.UUID
import           Data.UUID.V4
import           Database.Persist (upsert, getBy, entityVal)
import           Database.Persist.Sql (runMigration)
import           Database.Persist.Sqlite (runSqlite)
import qualified Graphics.UI.Gtk as Gtk
import           Network
import           Network.Google.OAuth2 ( formUrl, exchangeCode, refreshTokens
                                       , OAuth2Client(..), OAuth2Tokens(..))
import           Network.HTTP.Client (GivesPopper)
import           Network.HTTP.Conduit ( RequestBody(..), CookieJar (..), Manager (..)
                                      , cookieJar, createCookieJar
                                      , httpLbs, method, parseUrl
                                      , requestBody, requestHeaders
                                      , responseBody, responseCookieJar, withManager)
import           Network.HTTP.Types (methodPut)
import           System.Directory
import           System.Exit    (ExitCode(..))
import           System.FilePath ((</>),(<.>))
import           System.Info (os)
import           System.Process (rawSystem,readProcessWithExitCode)
--
import           Data.Hoodle.Generic
import           Data.Hoodle.Simple
import           Graphics.Hoodle.Render.Type.Hoodle
import           Text.Hoodle.Builder (builder)
--
import           Hoodle.Coroutine.Dialog
import           Hoodle.Coroutine.Hub.Common
import           Hoodle.Script.Hook
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Event
import           Hoodle.Type.Hub
import           Hoodle.Type.HoodleState
import           Hoodle.Type.Synchronization
--

         
uploadWork :: (FilePath,FilePath) -> HubInfo -> MainCoroutine ()
uploadWork (ofilepath,filepath) hinfo@(HubInfo {..}) = do
    uhdl <- view (unitHoodles.currentUnit) <$> get
    let mlastsyncmd5 = view (hoodleFileControl.lastSyncMD5) uhdl
        uhdluuid = view unitUUID uhdl
        hdl = (rHoodle2Hoodle . getHoodle) uhdl
    hdir <- liftIO $ getHomeDirectory
    msqlfile <- view (settings.sqliteFileName) <$> get
    let tokfile = hdir </> ".hoodle.d" </> "token.txt"
    prepareToken hinfo tokfile
    doIOaction $ \evhandler -> do 
      forkIO $ (`E.catch` (\(e :: E.SomeException)-> print e >> (Gtk.postGUIAsync . evhandler . UsrEv) (DisconnectedHub tokfile (ofilepath,filepath) hinfo) >> return ())) $ 
        withHub hinfo tokfile $ \manager coojar -> do
          let uuidtxt = TE.decodeUtf8 (view hoodleID hdl)
          flip runReaderT (manager,coojar) $ do
            mfstat <- sessionGetJSON (hubURL </> "sync" </> T.unpack uuidtxt)
            liftIO $ print (mfstat :: Maybe FileSyncStatus)
            liftIO $ print (mlastsyncmd5)
            let uploading = uploadAndUpdateSync evhandler uhdluuid hinfo uuidtxt hdl ofilepath filepath msqlfile
            flip (maybe uploading) ((,,) <$> msqlfile <*> mfstat <*> mlastsyncmd5) $ \(sqlfile,fstat,lastsyncmd5) -> do
              me <- runSqlite (T.pack sqlfile) $ getBy (UniqueFileSyncStatusUUID (fileSyncStatusUuid fstat))
              case me of 
                Just e -> do 
                  let remotemd5saved = fileSyncStatusMd5 fstat
                  if lastsyncmd5 /= remotemd5saved 
                    then liftIO $ evhandler (UsrEv (FileSyncFromHub uhdluuid fstat))
                    else uploading
                Nothing -> uploading
      return (UsrEv ActionOrdered)


uploadAndUpdateSync :: (AllEvent -> IO ()) -> UUID -> HubInfo -> T.Text -> Hoodle 
                    -> FilePath -> FilePath -> Maybe FilePath 
                    -> ReaderT (Manager,CookieJar) (ResourceT IO) ()
uploadAndUpdateSync evhandler uhdluuid hinfo uuidtxt hdl ofilepath filepath msqlfile = do
    mfrsync <- sessionGetJSON (hubURL hinfo </> "file" </> T.unpack uuidtxt) 
    let hdlbstr = (BL.toStrict . builder) hdl
    b64txt <- case mfrsync of 
      Nothing -> (return . TE.decodeUtf8 . B64.encode) hdlbstr
      Just frsync -> liftIO $ do
        let rsyncbstr = (B64.decodeLenient . TE.encodeUtf8 . frsync_sig) frsync
        tdir <- getTemporaryDirectory
        uuid'' <- nextRandom
        let tsigfile = tdir </> show uuid'' <.> "sig"
            tdeltafile = tdir </> show uuid'' <.> "delta"
        B.writeFile tsigfile rsyncbstr
        readProcessWithExitCode "rdiff" 
          ["delta", tsigfile, ofilepath, tdeltafile] ""
        deltabstr <- B.readFile tdeltafile 
        mapM_ removeFile [tsigfile,tdeltafile]
        (return . TE.decodeUtf8 . B64.encode) deltabstr
    let filecontent = toJSON FileContent { file_uuid = uuidtxt
                                         , file_path = T.pack filepath
                                         , file_content = b64txt 
                                         , file_rsync = mfrsync 
                                         , client_uuid = T.pack (show uhdluuid)
                                         }
        filecontentbstr = encode filecontent
    (manager,coojar) <- ask
    request3' <- lift $ parseUrl (hubURL hinfo </> "file" </> T.unpack uuidtxt )
    let request3 = request3' { method = methodPut
                             , requestBody = RequestBodyStreamChunked (streamContent filecontentbstr)
                             , cookieJar = Just coojar }
    _response3 <- lift $ httpLbs request3 manager
    mfstat2 :: Maybe FileSyncStatus 
      <- sessionGetJSON (hubURL hinfo </> "sync" </> T.unpack uuidtxt)
    F.forM_ ((,) <$> msqlfile <*> mfstat2) $ \(sqlfile,fstat2) -> do 
      runSqlite (T.pack sqlfile) $ upsert fstat2 []
      liftIO $ evhandler (UsrEv (SyncInfoUpdated uhdluuid fstat2))
      return ()
    return ()


initSqliteDB :: MainCoroutine ()
initSqliteDB = do
    msqlfile <- view (settings.sqliteFileName) <$> get
    F.forM_ msqlfile $ \sqlfile -> liftIO $ do
      runSqlite (T.pack sqlfile) $ runMigration $ migrateAll

updateSyncInfo :: UUID -> FileSyncStatus -> MainCoroutine ()
updateSyncInfo uuid fstat = do
    liftIO $ putStrLn "updateSyncInfo called"
    uhdlsMap <-  snd . view unitHoodles <$> get
    let uhdls = IM.elems uhdlsMap
    case find (\x -> view unitUUID x == uuid) uhdls of 
      Nothing -> return ()
      Just uhdl -> do 
        let nuhdlsMap = IM.adjust (set (hoodleFileControl.lastSyncMD5) (Just (fileSyncStatusMd5 fstat)) ) (view unitKey uhdl) uhdlsMap
        modify (set (unitHoodles._2) nuhdlsMap)
    
fileSyncFromHub :: UUID -> FileSyncStatus -> MainCoroutine ()
fileSyncFromHub unituuid fstat = do
    liftIO $ putStrLn "fileSyncFromHub called"
    uhdlsMap <-  snd . view unitHoodles <$> get
    let uhdls = IM.elems uhdlsMap

    hdir <- liftIO $ getHomeDirectory
    let tokfile = hdir </> ".hoodle.d" </> "token.txt"
    xst <- get
    runMaybeT $ do
      uhdl <- (MaybeT . return . find (\x -> view unitUUID x == unituuid)) uhdls 
      hdlfile <- (MaybeT . return . view (hoodleFileControl.hoodleFileName)) uhdl
      hset <- (MaybeT . return . view hookSet) xst
      hinfo <- (MaybeT . return) (hubInfo hset)
      lift $ prepareToken hinfo tokfile
      lift $ doIOaction $ \evhandler -> do 
        forkIO $ (`E.catch` (\(e :: E.SomeException)-> print e >> return ())) $ 
          withHub hinfo tokfile $ \manager coojar -> do
            runReaderT (rsyncPatchWork evhandler hinfo hdlfile fstat) (manager,coojar)
{-             sigtxt <- liftIO $ do 
                        uuid' <- nextRandom
                        tdir <- getTemporaryDirectory
                        let sigfile = tdir </> show uuid' <.> "sig"
                        readProcessWithExitCode "rdiff" ["signature", hdlfile, sigfile] ""
                        bstr <- B.readFile sigfile
                        return (TE.decodeUtf8 (B64.encode bstr))
            let frsync = FileRsync uuidtxt sigtxt
                frsyncjsonbstr = (encode . toJSON) frsync
            req' <- lift $ parseUrl (hubURL hinfo </> "rsyncdown" </> T.unpack uuidtxt)
            let req = req' { cookieJar = Just coojar 
                           , requestBody = RequestBodyStreamChunked (streamContent frsyncjsonbstr)
                           }
            mfcont <- lift $ AE.decode . responseBody <$> httpLbs req manager
            F.forM_ mfcont $ \fcont -> do
              let filebstr = (B64.decodeLenient . TE.encodeUtf8 . file_content) fcont 
              liftIO $ do 
                uuid' <- nextRandom
                tdir <- getTemporaryDirectory 
                let deltafile = tdir </> show uuid' <.> "delta"
                    newfile = tdir </> show uuid' <.> "hdlnew"
                B.writeFile deltafile filebstr
                readProcessWithExitCode "rdiff" ["patch", hdlfile, deltafile, newfile] ""
                md5str <- show . md5 <$> BL.readFile newfile 
                when (md5str == T.unpack (fileSyncStatusMd5 fstat)) $ do
                  copyFile newfile hdlfile
                  mapM_ removeFile [deltafile,newfile]
                  (Gtk.postGUIAsync . evhandler . UsrEv) FileReloadOrdered  -}
        return (UsrEv ActionOrdered)
    return ()



rsyncPatchWork evhandler hinfo hdlfile fstat = do 
    (manager,coojar) <- ask
    let uuidtxt = fileSyncStatusUuid fstat
    sigtxt <- liftIO $ do 
                uuid' <- nextRandom
                tdir <- getTemporaryDirectory
                let sigfile = tdir </> show uuid' <.> "sig"
                readProcessWithExitCode "rdiff" ["signature", hdlfile, sigfile] ""
                bstr <- B.readFile sigfile
                return (TE.decodeUtf8 (B64.encode bstr))
    let frsync = FileRsync uuidtxt sigtxt
        frsyncjsonbstr = (encode . toJSON) frsync
    req' <- lift $ parseUrl (hubURL hinfo </> "rsyncdown" </> T.unpack uuidtxt)
    let req = req' { cookieJar = Just coojar 
                   , requestBody = RequestBodyStreamChunked (streamContent frsyncjsonbstr)
                   }
    mfcont <- lift $ AE.decode . responseBody <$> httpLbs req manager
    F.forM_ mfcont $ \fcont -> do
      let filebstr = (B64.decodeLenient . TE.encodeUtf8 . file_content) fcont 
      liftIO $ do 
        uuid' <- nextRandom
        tdir <- getTemporaryDirectory 
        let deltafile = tdir </> show uuid' <.> "delta"
            newfile = tdir </> show uuid' <.> "hdlnew"
        B.writeFile deltafile filebstr
        readProcessWithExitCode "rdiff" ["patch", hdlfile, deltafile, newfile] ""
        md5str <- show . md5 <$> BL.readFile newfile 
        when (md5str == T.unpack (fileSyncStatusMd5 fstat)) $ do
          copyFile newfile hdlfile
          mapM_ removeFile [deltafile,newfile]
          (Gtk.postGUIAsync . evhandler . UsrEv) FileReloadOrdered 

            

gotSyncEvent :: UUID -> UUID -> MainCoroutine ()
gotSyncEvent fileuuid uhdluuid = do
    liftIO $ putStrLn "gotSyncEvent called"
    liftIO $ putStrLn (show fileuuid)
    uhdlsMap <-  snd . view unitHoodles <$> get
    let uhdls = IM.elems uhdlsMap
    hdir <- liftIO $ getHomeDirectory
    let tokfile = hdir </> ".hoodle.d" </> "token.txt"
        uuidtxt = T.pack (show fileuuid)
    xst <- get
    case find (\x -> view unitUUID x == uhdluuid) uhdls of
      Just _ -> return () 
      Nothing -> do 
        mapM_ (liftIO . putStrLn . show . view ghoodleID . getHoodle) uhdls 
        runMaybeT $ do
          uhdl <- (MaybeT . return .  find (\x -> B.unpack (view ghoodleID (getHoodle x)) == show fileuuid)) uhdls 
          liftIO $ print "i am here"
          hdlfile <- (MaybeT . return . view (hoodleFileControl.hoodleFileName)) uhdl

          hset <- (MaybeT . return . view hookSet) xst
          hinfo <- (MaybeT . return) (hubInfo hset)
          lift $ prepareToken hinfo tokfile 
          lift $ doIOaction $ \evhandler -> do 
            forkIO $ (`E.catch` (\(e :: E.SomeException)-> print e >> return ())) $ 
              withHub hinfo tokfile $ \manager coojar -> do
                flip runReaderT (manager,coojar) $ do
                  mfstat <- sessionGetJSON (hubURL hinfo </> "sync" </> T.unpack uuidtxt)
                  liftIO $ print mfstat
                  F.forM_ mfstat $ \fstat -> do 
                    rsyncPatchWork evhandler hinfo hdlfile fstat
            return (UsrEv ActionOrdered)
        return () 
