{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module UnitTests.Distribution.Client.FileMonitor (tests) where

import Control.Monad
import Control.Exception
import Control.Concurrent (threadDelay)
import qualified Data.Set as Set
import System.FilePath
import System.Directory

import Distribution.Text (simpleParse)
import Distribution.Compat.Binary
import Distribution.Simple.Utils (withTempDirectory)
import Distribution.Verbosity (silent)

import Distribution.Client.FileMonitor
import Distribution.Client.Compat.Time

import Test.Tasty
import Test.Tasty.HUnit


tests :: Int -> [TestTree]
tests mtimeChange =
  [ testCase "sanity check mtimes"   $ testFileMTimeSanity mtimeChange
  , testCase "no monitor cache"      testNoMonitorCache
  , testCase "corrupt monitor cache" testCorruptMonitorCache
  , testCase "empty monitor"         testEmptyMonitor
  , testCase "missing file"          testMissingFile
  , testCase "change file"           $ testChangedFile mtimeChange
  , testCase "file mtime vs content" $ testChangedFileMtimeVsContent mtimeChange
  , testCase "update during action"  $ testUpdateDuringAction mtimeChange
  , testCase "remove file"           testRemoveFile
  , testCase "non-existent file"     testNonExistentFile

  , testGroup "glob matches"
    [ testCase "no change"           testGlobNoChange
    , testCase "add match"           $ testGlobAddMatch mtimeChange
    , testCase "remove match"        testGlobRemoveMatch
    , testCase "change match"        $ testGlobChangeMatch mtimeChange

    , testCase "add match subdir"    $ testGlobAddMatchSubdir mtimeChange
    , testCase "remove match subdir" testGlobRemoveMatchSubdir
    , testCase "change match subdir" $ testGlobChangeMatchSubdir mtimeChange

    , testCase "add non-match"       $ testGlobAddNonMatch mtimeChange
    , testCase "remove non-match"    testGlobRemoveNonMatch

    , testCase "add non-match"       $ testGlobAddNonMatchSubdir mtimeChange
    , testCase "remove non-match"    testGlobRemoveNonMatchSubdir

    , testCase "invariant sorted 1"  $ testInvariantMonitorStateGlobFiles
      mtimeChange
    , testCase "invariant sorted 2"  $ testInvariantMonitorStateGlobDirs
      mtimeChange
    ]

  , testCase "value unchanged"       testValueUnchanged
  , testCase "value changed"         testValueChanged
  , testCase "value & file changed"  $ testValueAndFileChanged mtimeChange
  , testCase "value updated"         testValueUpdated
  ]

-- we rely on file mtimes having a reasonable resolution
testFileMTimeSanity :: Int -> Assertion
testFileMTimeSanity mtimeChange =
  withTempDirectory silent "." "file-status-" $ \dir -> do
    replicateM_ 10 $ do
      writeFile (dir </> "a") "content"
      t1 <- getModTime (dir </> "a")
      threadDelay mtimeChange
      writeFile (dir </> "a") "content"
      t2 <- getModTime (dir </> "a")
      assertBool "expected different file mtimes" (t2 > t1)

-- first run, where we don't even call updateMonitor
testNoMonitorCache :: Assertion
testNoMonitorCache =
  withFileMonitor $ \root monitor -> do
    reason <- expectMonitorChanged root (monitor :: FileMonitor () ()) ()
    reason @?= MonitorFirstRun

-- write garbage into the binary cache file
testCorruptMonitorCache :: Assertion
testCorruptMonitorCache =
  withFileMonitor $ \root monitor -> do
    writeFile (fileMonitorCacheFile monitor) "broken"
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitorCorruptCache

    updateMonitor root monitor [] () ()
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= []

    writeFile (fileMonitorCacheFile monitor) "broken"
    reason2 <- expectMonitorChanged root monitor ()
    reason2 @?= MonitorCorruptCache

-- no files to monitor
testEmptyMonitor :: Assertion
testEmptyMonitor =
  withFileMonitor $ \root monitor -> do
    touch root "a"
    updateMonitor root monitor [] () ()
    touch root "b"
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= []

-- monitor a file that is expected to exist
testMissingFile :: Assertion
testMissingFile = do
    test MonitorFile       "a"
    test MonitorFileHashed "a"
    test MonitorFile       ("dir" </> "a")
    test MonitorFileHashed ("dir" </> "a")
  where
    test monitorKind file =
      withFileMonitor $ \root monitor -> do
        -- a file that doesn't exist at snapshot time is considered to have
        -- changed
        updateMonitor root monitor [monitorKind file] () ()
        reason <- expectMonitorChanged root monitor ()
        reason @?= MonitoredFileChanged file

        -- a file doesn't exist at snapshot time, but gets added afterwards is
        -- also considered to have changed
        updateMonitor root monitor [monitorKind file] () ()
        touch root file
        reason2 <- expectMonitorChanged root monitor ()
        reason2 @?= MonitoredFileChanged file


testChangedFile :: Int -> Assertion
testChangedFile mtimeChange = do
    test MonitorFile       "a"
    test MonitorFileHashed "a"
    test MonitorFile       ("dir" </> "a")
    test MonitorFileHashed ("dir" </> "a")
  where
    test monitorKind file =
      withFileMonitor $ \root monitor -> do
        touch root file
        updateMonitor root monitor [monitorKind file] () ()
        threadDelay mtimeChange
        write root file "different"
        reason <- expectMonitorChanged root monitor ()
        reason @?= MonitoredFileChanged file


testChangedFileMtimeVsContent :: Int -> Assertion
testChangedFileMtimeVsContent mtimeChange =
  withFileMonitor $ \root monitor -> do
    -- if we don't touch the file, it's unchanged
    touch root "a"
    updateMonitor root monitor [MonitorFile "a"] () ()
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [MonitorFile "a"]

    -- if we do touch the file, it's changed if we only consider mtime
    updateMonitor root monitor [MonitorFile "a"] () ()
    threadDelay mtimeChange
    touch root "a"
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged "a"

    -- but if we touch the file, it's unchanged if we consider content hash
    updateMonitor root monitor [MonitorFileHashed "a"] () ()
    threadDelay mtimeChange
    touch root "a"
    (res2, files2) <- expectMonitorUnchanged root monitor ()
    res2   @?= ()
    files2 @?= [MonitorFileHashed "a"]

    -- finally if we change the content it's changed
    updateMonitor root monitor [MonitorFileHashed "a"] () ()
    threadDelay mtimeChange
    write root "a" "different"
    reason2 <- expectMonitorChanged root monitor ()
    reason2 @?= MonitoredFileChanged "a"


testUpdateDuringAction :: Int -> Assertion
testUpdateDuringAction mtimeChange = do
    test (MonitorFile "a")       "a"
    test (MonitorFileHashed "a") "a"
    test (monitorFileGlob "*")   "a"
  where
    test monitorSpec file =
      withFileMonitor $ \root monitor -> do
        touch root file
        updateMonitor root monitor [monitorSpec] () ()

        -- start doing an update action...
        threadDelay mtimeChange -- some time passes
        touch root file         -- a file gets updates during the action
        threadDelay mtimeChange -- some time passes then we finish
        updateMonitor root monitor [monitorSpec] () ()
        -- we don't notice this change since we took the timestamp after the
        -- action finished
        (res, files) <- expectMonitorUnchanged root monitor ()
        res   @?= ()
        files @?= [monitorSpec]

        -- Let's try again, this time taking the timestamp before the action
        timestamp' <- beginUpdateFileMonitor
        threadDelay mtimeChange -- some time passes
        touch root file         -- a file gets updates during the action
        threadDelay mtimeChange -- some time passes then we finish
        updateMonitorWithTimestamp root monitor timestamp' [monitorSpec] () ()
        -- now we do notice the change since we took the snapshot before the
        -- action finished
        reason <- expectMonitorChanged root monitor ()
        reason @?= MonitoredFileChanged file


testRemoveFile :: Assertion
testRemoveFile = do
    test MonitorFile       "a"
    test MonitorFileHashed "a"
    test MonitorFile       ("dir" </> "a")
    test MonitorFileHashed ("dir" </> "a")
  where
    test monitorKind file =
      withFileMonitor $ \root monitor -> do
        touch root file
        updateMonitor root monitor [monitorKind file] () ()
        remove root file
        reason <- expectMonitorChanged root monitor ()
        reason @?= MonitoredFileChanged file


-- monitor a file that we expect not to exist
testNonExistentFile :: Assertion
testNonExistentFile =
  withFileMonitor $ \root monitor -> do
    -- a file that doesn't exist at snapshot time or check time is unchanged
    updateMonitor root monitor [MonitorNonExistentFile "a"] () ()
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [MonitorNonExistentFile "a"]

    -- if the file then exists it has changed
    touch root "a"
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged "a"

    -- if the file then exists at snapshot and check time it has changed
    updateMonitor root monitor [MonitorNonExistentFile "a"] () ()
    reason2 <- expectMonitorChanged root monitor ()
    reason2 @?= MonitoredFileChanged "a"

    -- but if the file existed at snapshot time and doesn't exist at check time
    -- it is consider unchanged. This is unlike files we expect to exist, but
    -- that's because files that exist can have different content and actions
    -- can depend on that content, whereas if the action expected a file not to
    -- exist and it now does not, it'll give the same result, irrespective of
    -- the fact that the file might have existed in the meantime.
    updateMonitor root monitor [MonitorNonExistentFile "a"] () ()
    remove root "a"
    (res2, files2) <- expectMonitorUnchanged root monitor ()
    res2   @?= ()
    files2 @?= [MonitorNonExistentFile "a"]


------------------
-- globs
--

testGlobNoChange :: Assertion
testGlobNoChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "good-a")
    touch root ("dir" </> "good-b")
    updateMonitor root monitor [monitorFileGlob "dir/good-*"] () ()
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/good-*"]

testGlobAddMatch :: Int -> Assertion
testGlobAddMatch mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "good-a")
    updateMonitor root monitor [monitorFileGlob "dir/good-*"] () ()
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/good-*"]

    threadDelay mtimeChange
    touch root ("dir" </> "good-b")
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged ("dir" </> "good-b")

testGlobRemoveMatch :: Assertion
testGlobRemoveMatch =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "good-a")
    touch root ("dir" </> "good-b")
    updateMonitor root monitor [monitorFileGlob "dir/good-*"] () ()
    remove root "dir/good-a"
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged ("dir" </> "good-a")

testGlobChangeMatch :: Int -> Assertion
testGlobChangeMatch mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "good-a")
    touch root ("dir" </> "good-b")
    updateMonitor root monitor [monitorFileGlob "dir/good-*"] () ()
    threadDelay mtimeChange
    touch root ("dir" </> "good-b")
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/good-*"]

    write root ("dir" </> "good-b") "different"
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged ("dir" </> "good-b")

testGlobAddMatchSubdir :: Int -> Assertion
testGlobAddMatchSubdir mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "a" </> "good-a")
    updateMonitor root monitor [monitorFileGlob "dir/*/good-*"] () ()
    threadDelay mtimeChange
    touch root ("dir" </> "b" </> "good-b")
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged ("dir" </> "b" </> "good-b")

testGlobRemoveMatchSubdir :: Assertion
testGlobRemoveMatchSubdir =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "a" </> "good-a")
    touch root ("dir" </> "b" </> "good-b")
    updateMonitor root monitor [monitorFileGlob "dir/*/good-*"] () ()
    removeDir root ("dir" </> "a")
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged ("dir" </> "a" </> "good-a")

testGlobChangeMatchSubdir :: Int -> Assertion
testGlobChangeMatchSubdir mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "a" </> "good-a")
    touch root ("dir" </> "b" </> "good-b")
    updateMonitor root monitor [monitorFileGlob "dir/*/good-*"] () ()
    threadDelay mtimeChange
    touch root ("dir" </> "b" </> "good-b")
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/*/good-*"]

    write root "dir/b/good-b" "different"
    reason <- expectMonitorChanged root monitor ()
    reason @?= MonitoredFileChanged ("dir" </> "b" </> "good-b")

testGlobAddNonMatch :: Int -> Assertion
testGlobAddNonMatch mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "good-a")
    updateMonitor root monitor [monitorFileGlob "dir/good-*"] () ()
    threadDelay mtimeChange
    touch root ("dir" </> "bad")
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/good-*"]

testGlobRemoveNonMatch :: Assertion
testGlobRemoveNonMatch =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "good-a")
    touch root ("dir" </> "bad")
    updateMonitor root monitor [monitorFileGlob "dir/good-*"] () ()
    remove root "dir/bad"
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/good-*"]

testGlobAddNonMatchSubdir :: Int -> Assertion
testGlobAddNonMatchSubdir mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "a" </> "good-a")
    updateMonitor root monitor [monitorFileGlob "dir/*/good-*"] () ()
    threadDelay mtimeChange
    touch root ("dir" </> "b" </> "bad")
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/*/good-*"]

testGlobRemoveNonMatchSubdir :: Assertion
testGlobRemoveNonMatchSubdir =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "a" </> "good-a")
    touch root ("dir" </> "b" </> "bad")
    updateMonitor root monitor [monitorFileGlob "dir/*/good-*"] () ()
    removeDir root ("dir" </> "b")
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/*/good-*"]


-- try and tickle a bug that happens if we don't maintain the invariant that
-- MonitorStateGlobFiles entries are sorted
testInvariantMonitorStateGlobFiles :: Int -> Assertion
testInvariantMonitorStateGlobFiles mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "a")
    touch root ("dir" </> "b")
    touch root ("dir" </> "c")
    touch root ("dir" </> "d")
    updateMonitor root monitor [monitorFileGlob "dir/*"] () ()
    threadDelay mtimeChange
    -- so there should be no change (since we're doing content checks)
    -- but if we can get the dir entries to appear in the wrong order
    -- then if the sorted invariant is not maintained then we can fool
    -- the 'probeGlobStatus' into thinking there's changes
    remove root ("dir" </> "a")
    remove root ("dir" </> "b")
    remove root ("dir" </> "c")
    remove root ("dir" </> "d")
    touch root ("dir" </> "d")
    touch root ("dir" </> "c")
    touch root ("dir" </> "b")
    touch root ("dir" </> "a")
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/*"]

-- same thing for the subdirs case
testInvariantMonitorStateGlobDirs :: Int -> Assertion
testInvariantMonitorStateGlobDirs mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root ("dir" </> "a" </> "file")
    touch root ("dir" </> "b" </> "file")
    touch root ("dir" </> "c" </> "file")
    touch root ("dir" </> "d" </> "file")
    updateMonitor root monitor [monitorFileGlob "dir/*/file"] () ()
    threadDelay mtimeChange
    removeDir root ("dir" </> "a")
    removeDir root ("dir" </> "b")
    removeDir root ("dir" </> "c")
    removeDir root ("dir" </> "d")
    touch root ("dir" </> "d" </> "file")
    touch root ("dir" </> "c" </> "file")
    touch root ("dir" </> "b" </> "file")
    touch root ("dir" </> "a" </> "file")
    (res, files) <- expectMonitorUnchanged root monitor ()
    res   @?= ()
    files @?= [monitorFileGlob "dir/*/file"]


------------------
-- value changes
--

testValueUnchanged :: Assertion
testValueUnchanged =
  withFileMonitor $ \root monitor -> do
    touch root "a"
    updateMonitor root monitor [MonitorFile "a"] (42 :: Int) "ok"
    (res, files) <- expectMonitorUnchanged root monitor 42
    res   @?= "ok"
    files @?= [MonitorFile "a"]

testValueChanged :: Assertion
testValueChanged =
  withFileMonitor $ \root monitor -> do
    touch root "a"
    updateMonitor root monitor [MonitorFile "a"] (42 :: Int) "ok"
    reason <- expectMonitorChanged root monitor 43
    reason @?= MonitoredValueChanged 42

testValueAndFileChanged :: Int -> Assertion
testValueAndFileChanged mtimeChange =
  withFileMonitor $ \root monitor -> do
    touch root "a"

    -- we change the value and the file, and the value change is reported
    updateMonitor root monitor [MonitorFile "a"] (42 :: Int) "ok"
    threadDelay mtimeChange
    touch root "a"
    reason <- expectMonitorChanged root monitor 43
    reason @?= MonitoredValueChanged 42

    -- if fileMonitorCheckIfOnlyValueChanged then if only the value changed
    -- then it's reported as MonitoredValueChanged
    let monitor' :: FileMonitor Int String
        monitor' = monitor { fileMonitorCheckIfOnlyValueChanged = True }
    updateMonitor root monitor' [MonitorFile "a"] 42 "ok"
    reason2 <- expectMonitorChanged root monitor' 43
    reason2 @?= MonitoredValueChanged 42

    -- but if a file changed too then we don't report MonitoredValueChanged
    updateMonitor root monitor' [MonitorFile "a"] 42 "ok"
    threadDelay mtimeChange
    touch root "a"
    reason3 <- expectMonitorChanged root monitor' 43
    reason3 @?= MonitoredFileChanged "a"

testValueUpdated :: Assertion
testValueUpdated =
  withFileMonitor $ \root monitor -> do
    touch root "a"

    let monitor' :: FileMonitor (Set.Set Int) String
        monitor' = (monitor :: FileMonitor (Set.Set Int) String) {
                     fileMonitorCheckIfOnlyValueChanged = True,
                     fileMonitorKeyValid = Set.isSubsetOf
                   }

    updateMonitor root monitor' [MonitorFile "a"] (Set.fromList [42,43]) "ok"
    (res,_files) <- expectMonitorUnchanged root monitor' (Set.fromList [42])
    res @?= "ok"

    reason <- expectMonitorChanged root monitor' (Set.fromList [42,44])
    reason @?= MonitoredValueChanged (Set.fromList [42,43])


-------------
-- Utils

newtype RootPath = RootPath FilePath

write :: RootPath -> FilePath -> String -> IO ()
write (RootPath root) fname contents = do
  let path = root </> fname
  createDirectoryIfMissing True (takeDirectory path)
  writeFile path contents

touch :: RootPath -> FilePath -> IO ()
touch root fname = write root fname "hello"

remove :: RootPath -> FilePath -> IO ()
remove (RootPath root) fname = removeFile (root </> fname)

removeDir :: RootPath -> FilePath -> IO ()
removeDir (RootPath root) dname = removeDirectoryRecursive (root </> dname)

monitorFileGlob :: String -> MonitorFilePath
monitorFileGlob globstr
  | Just glob <- simpleParse globstr = MonitorFileGlob glob
  | otherwise                        = error $ "Failed to parse " ++ globstr


expectMonitorChanged :: (Binary a, Binary b)
                     => RootPath -> FileMonitor a b -> a
                     -> IO (MonitorChangedReason a)
expectMonitorChanged root monitor key = do
  res <- checkChanged root monitor key
  case res of
    MonitorChanged reason -> return reason
    MonitorUnchanged _ _  -> throwIO $ HUnitFailure "expected change"

expectMonitorUnchanged :: (Binary a, Binary b)
                        => RootPath -> FileMonitor a b -> a
                        -> IO (b, [MonitorFilePath])
expectMonitorUnchanged root monitor key = do
  res <- checkChanged root monitor key
  case res of
    MonitorChanged _reason   -> throwIO $ HUnitFailure "expected no change"
    MonitorUnchanged b files -> return (b, files)

checkChanged :: (Binary a, Binary b)
             => RootPath -> FileMonitor a b
             -> a -> IO (MonitorChanged a b)
checkChanged (RootPath root) monitor key =
  checkFileMonitorChanged monitor root key

updateMonitor :: (Binary a, Binary b)
              => RootPath -> FileMonitor a b
              -> [MonitorFilePath] -> a -> b -> IO ()
updateMonitor (RootPath root) monitor files key result =
  updateFileMonitor monitor root Nothing files key result

updateMonitorWithTimestamp :: (Binary a, Binary b)
              => RootPath -> FileMonitor a b -> MonitorTimestamp
              -> [MonitorFilePath] -> a -> b -> IO ()
updateMonitorWithTimestamp (RootPath root) monitor timestamp files key result =
  updateFileMonitor monitor root (Just timestamp) files key result

withFileMonitor :: Eq a => (RootPath -> FileMonitor a b -> IO c) -> IO c
withFileMonitor action = do
  withTempDirectory silent "." "file-status-" $ \root -> do
    let monitorFile = root <.> "monitor"
        monitor   = newFileMonitor monitorFile
    finally (action (RootPath root) monitor) $ do
      exists <- doesFileExist monitorFile
      when exists $ removeFile monitorFile
