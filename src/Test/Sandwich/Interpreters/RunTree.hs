{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiWayIf #-}
-- |

module Test.Sandwich.Interpreters.RunTree (
  runTreeMain
  , RunTreeContext(..)
  , getImmediateChildren
  ) where

import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import Control.Monad.Free
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State
import Data.IORef
import Data.Time.Clock
import Test.Sandwich.Types.Example
import Test.Sandwich.Types.Options
import Test.Sandwich.Types.RunTree
import Test.Sandwich.Types.Spec


waitForTree :: [RunTree] -> IO Result
waitForTree rts = do
  results <- mapM wait (fmap runTreeAsync rts)
  return $ if | any isFailure results -> Failure Nothing (Reason "Some child nodes failed")
              | otherwise -> Success

data RunTreeContext context = RunTreeContext {
  runTreeContext :: Async context
  , runTreeOptions :: Options
  }

runTreeMain :: (Show context) => Free (SpecCommand context) () -> ReaderT (RunTreeContext context) IO [RunTree]
runTreeMain spec = do
  [RunTreeGroup {..}] <- runTree (Free (Describe "implicit outer describe" spec (Pure ())))
  return runTreeChildren


runTree :: (Show r, Show context) => Free (SpecCommand context) r -> ReaderT (RunTreeContext context) IO [RunTree]

runTree (Free (Before l f subspec next)) = do
  status <- liftIO $ newIORef NotStarted

  rtc@RunTreeContext {..} <- ask

  newContextAsync <- liftIO $ async $ do
    ctx <- wait runTreeContext

    startTime <- getCurrentTime
    atomicWriteIORef status (Running startTime)

    (try $ f ctx) >>= \case
      Left (e :: SomeException) -> do
        let maybeLoc = Nothing
        endTime <- getCurrentTime
        atomicWriteIORef status (Done startTime endTime (Failure maybeLoc (Error (Just "Exception in before handler") e)))
        throwIO e
      Right () -> do
        endTime <- getCurrentTime
        atomicWriteIORef status (Done startTime endTime Success)
    return ctx

  subtree <- withReaderT (const $ rtc { runTreeContext = newContextAsync }) $ runTree subspec

  myAsync <- liftIO $ async $ do
    mapM_ wait (fmap runTreeAsync subtree)
    return Success

  let tree = RunTreeGroup l status True subtree myAsync
  rest <- runTree next
  return (tree : rest)


runTree (Free (After l f subspec next)) = do
  status <- liftIO $ newIORef NotStarted

  RunTreeContext {..} <- ask

  subtree <- runTree subspec

  myAsync <- liftIO $ async $ do
    _ <- waitForTree subtree
    ctx <- wait runTreeContext

    startTime <- getCurrentTime
    atomicWriteIORef status (Running startTime)

    (try $ f ctx) >>= \case
      Left (e :: SomeException) -> do
        let maybeLoc = Nothing
        endTime <- getCurrentTime
        let ret = Failure maybeLoc (Error (Just "Exception in after handler") e)
        atomicWriteIORef status (Done startTime endTime ret)
        return ret
      Right () -> do
        endTime <- getCurrentTime
        let ret = Success
        atomicWriteIORef status (Done startTime endTime ret)
        return ret

  let tree = RunTreeGroup l status True subtree myAsync
  rest <- runTree next
  return (tree : rest)


runTree (Free (Introduce l alloc cleanup subspec next)) = do
  status <- liftIO $ newIORef NotStarted

  rtc@RunTreeContext {..} <- ask

  newContextAsync <- liftIO $ async $ do
    ctx <- wait runTreeContext

    startTime <- getCurrentTime
    atomicWriteIORef status (Running startTime)

    (try $ alloc ctx) >>= \case
      Left (e :: SomeException) -> do
        let maybeLoc = Nothing
        endTime <- getCurrentTime
        atomicWriteIORef status (Done startTime endTime (Failure maybeLoc (Error (Just "Exception in introduce allocate handler") e)))
        throwIO e
      Right intro -> do
        endTime <- getCurrentTime
        atomicWriteIORef status (Done startTime endTime Success)
        return (intro :> ctx)

  subtree <- withReaderT (const $ rtc { runTreeContext = newContextAsync }) $ runTree subspec

  myAsync <- liftIO $ async $ do
    _ <- waitForTree subtree
    ctx <- wait newContextAsync

    startTime <- getCurrentTime -- TODO

    (try $ cleanup ctx) >>= \case
      Left (e :: SomeException) -> do
        let maybeLoc = Nothing
        endTime <- getCurrentTime
        let ret = Failure maybeLoc (Error (Just "Exception in introduce cleanup handler") e)
        atomicWriteIORef status (Done startTime endTime ret)
        return ret
      Right () -> do
        endTime <- getCurrentTime
        let ret = Success
        atomicWriteIORef status (Done startTime endTime ret)
        return ret

  let tree = RunTreeGroup l status True subtree myAsync
  rest <- runTree next
  return (tree : rest)


runTree (Free (It l ex next)) = do
  RunTreeContext {..} <- ask
  status <- liftIO $ newIORef NotStarted

  myAsync <- liftIO $ async $ do
    ctx <- wait runTreeContext
    startTime <- getCurrentTime
    atomicWriteIORef status (Running startTime)
    (try $ ex ctx) >>= \case
      Left (e :: SomeException) -> do
        let maybeLoc = Nothing
        endTime <- getCurrentTime
        let ret = Failure maybeLoc (Error (Just "Unknown exception") e)
        atomicWriteIORef status (Done startTime endTime ret)
        return ret
      Right ret -> do
        endTime <- getCurrentTime
        atomicWriteIORef status (Done startTime endTime ret)
        return ret

  let tree = RunTreeSingle l status myAsync

  rest <- runTree next
  return (tree : rest)


runTree (Free (Describe l subspec next)) = runDescribe False l subspec next

runTree (Free (DescribeParallel l subspec next)) = runDescribe True l subspec next

runTree (Pure _) = return []



runDescribe :: (Show a, Show r) => Bool -> [Char] -> Free (SpecCommand a) () -> Free (SpecCommand a) r -> ReaderT (RunTreeContext a) IO [RunTreeWithStatus (IORef Status)]
runDescribe parallel l subspec next = do
  status <- liftIO $ newIORef NotStarted

  rtc@RunTreeContext {..} <- ask

  (mconcat -> subtree) <- flip evalStateT runTreeContext $
    forM (getImmediateChildren subspec) $ \child -> do
      contextAsync <- get
      let asyncToUse = if parallel then runTreeContext else contextAsync
      tree <- lift $ withReaderT (const $ rtc { runTreeContext = asyncToUse }) $ runTree child
      put =<< liftIO (async $ waitForTree tree >> wait runTreeContext)
      return tree

  myAsync <- liftIO $ async $ do
    _ <- wait runTreeContext
    startTime <- getCurrentTime
    atomicWriteIORef status (Running startTime)
    _ <- waitForTree subtree
    endTime <- getCurrentTime
    let ret = Success
    atomicWriteIORef status (Done startTime endTime ret)
    return ret

  let tree = RunTreeGroup l status False subtree myAsync
  rest <- runTree next
  return (tree : rest)


  

getImmediateChildren :: Free (SpecCommand context) () -> [Free (SpecCommand context) ()]
getImmediateChildren (Free (It l ex next)) = (Free (It l ex (Pure ()))) : getImmediateChildren next
getImmediateChildren (Free (Before l f subspec next)) = (Free (Before l f subspec (Pure ()))) : getImmediateChildren next
getImmediateChildren (Free (After l f subspec next)) = (Free (After l f subspec (Pure ()))) : getImmediateChildren next
getImmediateChildren (Free (Introduce l alloc cleanup subspec next)) = (Free (Introduce l alloc cleanup subspec (Pure ()))) : getImmediateChildren next
getImmediateChildren (Free (Around l f subspec next)) = (Free (Around l f subspec (Pure ()))) : getImmediateChildren next
getImmediateChildren (Free (Describe l subspec next)) = (Free (Describe l subspec (Pure ()))) : getImmediateChildren next
getImmediateChildren (Free (DescribeParallel l subspec next)) = (Free (DescribeParallel l subspec (Pure ()))) : getImmediateChildren next
getImmediateChildren (Pure ()) = [Pure ()]
