{-# LANGUAGE ScopedTypeVariables, StandaloneDeriving, GADTs, Rank2Types #-}

module Main where

import Control.Concurrent 
import Control.Concurrent.MVar 
import Control.Monad.State
import Control.Monad.Trans.Error
-- import System.INotify 
-- from this package 
import Coroutine
import Driver 
import Event 
import EventHandler 
import Object 
-- import FileObserver 
-- import HINotify 
import Lsof 
-- import QServer

{-
-- | test qclient 
test_qclient :: IO () 
test_qclient = eaction >>= either putStrLn (const (putStrLn "good end")) 
  where eaction :: IO (Either String ())
        eaction = flip evalStateT qserver $ runErrorT $ do 
          r2 <- query $ do addQ (1 :: Int) 
                           addQ 2
                           addQ 3 
                           x <- retrieveQ  
                           y <- retrieveQ
                           return (x,y)
          liftIO $ print r2 
          r3  <- query $ do z <- retrieveQ 
                            return z 
          liftIO $ print r3  
-}


-- | test driver 
test_driver :: IO () 
test_driver = eaction >>= either (putStrLn.show) (const (putStrLn "good end"))
  where eaction :: IO (Either (CoroutineError ()) ())
        eaction = flip evalStateT driver $ runErrorT $ do 
          query $ dispatch (Message "hello")
          query $ dispatch (Message "how are you?")
          return () 
          
-- | test event handling 
test_eventhandler :: IO () 
test_eventhandler = do 
    dref <- newMVar driver 
    eventHandler dref (Message "hi")
    putStrLn "----"
    eventHandler dref (Message "hello")
    putStrLn "----"
    eventHandler dref (Message "dlsl") 
    putStrLn "----"
  
-- | test hinotify 
{- test_hinotify :: IO () 
test_hinotify = do 
    dref <- newMVar driver 
    let handler = eventHandler dref 
    handler (Message "hi")
    inotify <- initINotify 
    watchFile inotify "test.txt" handler 
    threadDelay 10000000000
    killINotify inotify  
-}

-- | test lsof
test_lsof :: IO () 
test_lsof = do 
    putStrLn "testing lsof"
    t <- checkLsof "test" 
    print t

-- | 
test_fileobserver :: IO () 
test_fileobserver = do 
    putStrLn "testing file observer"
    dref <- newMVar driver 
    eventHandler dref (Message "hi")
    putStrLn "----"
    eventHandler dref (Message "hello")
    putStrLn "----"
    eventHandler dref (Message "dlsl") 
    putStrLn "----"


-- |

test_tickingevent :: IO () 
test_tickingevent = do 
    dref <- newMVar driver 
    putStrLn "starting ticking" 
    ticking dref 0    


second :: Int 
second = 1000000

-- | 

ticking :: MVar (Driver IO ()) -> Int -> IO () 
ticking mvar n = do 
    putStrLn "--------------------------"
    putStrLn ("ticking : " ++ show n)
    if n `mod` 10 == 0 
    then eventHandler mvar Open 
    else if n `mod` 10 == 5                 
    then eventHandler mvar Close 
    else if n `mod` 10 == 3
    then eventHandler mvar Render
    else eventHandler mvar (Message ("test : " ++ show n))
    putStrLn "_-_-_-_-_-_-_-_-_-_-_-_-_-"
    threadDelay (1*second)
    ticking mvar (n+1)

------------------------------- 
-- test 
-------------------------------

main :: IO ()
main = do 
    -- test_qclient
    -- test_driver 
    -- test_eventhandler
    -- test_hinotify 
    -- test_lsof 
    -- test_fileobserver
    test_tickingevent 
