import Control.Applicative ( (<$>), (<*>), pure )
import Control.Monad ( replicateM, when )
import Control.Monad.Random ( Rand, getRandomR, evalRandIO )
import Data.Char ( isAscii, isAlphaNum, isLetter )
import Data.List ( intercalate )
import Data.Monoid ( mempty )
import Distribution.Package ( PackageIdentifier(..), PackageName(..)
                            , packageId, packageName )
import Distribution.Simple.GHC ( getInstalledPackages )
import Distribution.Simple.Compiler ( PackageDB(..)
                                    )
import Distribution.Simple.Program ( configureAllKnownPrograms
                                   , addKnownPrograms
                                   , emptyProgramConfiguration
                                   , ghcPkgProgram
                                   , ghcProgram
                                   , ProgramConfiguration
                                   )
import Distribution.Simple.PackageIndex ( lookupSourcePackageId, allPackages
                                        , SearchResult(..), searchByName
                                        , PackageIndex
                                        )
import Distribution.InstalledPackageInfo ( installedPackageId )
import Distribution.Simple.Utils ( rawSystemStdout, withTempDirectory, info )
import Distribution.Text ( simpleParse, display )
import Distribution.Verbosity ( normal, Verbosity, showForCabal )
import Distribution.Version ( Version(..) )
import Distribution.Dev.InitPkgDb ( initPkgDb )
import Distribution.Dev.Sandbox ( newSandbox, pkgConf, Sandbox, KnownVersion, sandbox )
import System.Cmd ( rawSystem )
import System.Directory ( getTemporaryDirectory, createDirectory )
import System.Environment ( getArgs )
import System.Exit ( ExitCode(ExitSuccess) )
import System.FilePath ( (</>), (<.>) )
import System.Random ( RandomGen )
import Test.Framework ( defaultMainWithArgs, Test, testGroup )
import Test.Framework.Providers.HUnit ( testCase )
import qualified Test.HUnit as HUnit

import Distribution.Client.Config -- ( parseConfig )
import Distribution.Client.Setup ( GlobalFlags(..) )
import Distribution.Simple.InstallDirs
import Distribution.Simple.Setup
import Distribution.ParseUtils
import Data.Function ( on )


tests :: FilePath -> [Test]
tests p =
    [ testGroup "Basic invocation tests" $ testBasicInvocation p
    , testGroup "Sandboxed" $
      [ testCase "add-source stays sandboxed (no-space dir)" $
        addSourceStaysSandboxed normal p "fake-package.",
        testCase "add-source stays sandboxed (dir with spaces)" $
        addSourceStaysSandboxed normal p "fake package."
      , testCase "Builds ok regardless of the state of the logs directory" $
        assertLogLocationOk normal p
      ]
    , testGroup "Parsing and serializing" $
      [ testCase "simple round-trip test" $
        assertRoundTrip

      -- , testCase "sample echo test" $
      --   configEcho
      ]
    ]

testBasicInvocation :: FilePath -> [Test]
testBasicInvocation p =
    [ testCase "--help exists with success" $
      assertExitsSuccess p ["--help"]

    , testCase "--version exists with success" $
      assertExitsSuccess p ["--version"]

    , testCase "--numeric-version has parseable output" $
      assertProgramOutput p ["--numeric-version"] $
      either fail return . checkNumericVersion

    , testCase "exits with failure when no arguments are supplied" $
      assertExitsFailure p []
    ]

main :: IO ()
main = do
  args <- getArgs

  -- The first argument is the cabal-dev executable. The remaining
  -- arguments are passed directly to test-framework
  let (cabalDev, testFrameworkArgs) =
          case args of
            (x:xs) -> (x, xs)
            []     -> ("cabal-dev", [])

  defaultMainWithArgs (tests cabalDev) testFrameworkArgs

-- configEcho :: HUnit.Assertion
-- configEcho = putStrLn $ showConfig sampleConfig

sampleConfig :: SavedConfig
sampleConfig = mempty { savedGlobalFlags = mempty { globalLocalRepos = ["/home/cre swick"]
                                                  , globalCacheDir = toFlag "/home/creswick/cabal files/cache/"}
                      , savedUserInstallDirs = mempty { prefix = toFlag $ toPathTemplate "/home/creswick/cabal files"
                                                      , bindir = toFlag $ toPathTemplate "/home/creswick/cabal files/some/bin" }
                      , savedConfigureFlags = mempty { configPackageDB = toFlag $
                                                           SpecificPackageDB "/home/creswick/cabal files/package.db"}
                      }

assertRoundTrip :: HUnit.Assertion
assertRoundTrip = do
  isEqual sampleConfig =<< roundTrip sampleConfig
  where roundTrip conf = case parseConfig mempty $ showConfig conf of
          ParseFailed err -> fail $ "Parse failed: "++show err
          ParseOk _ val   -> return val

isEqual :: SavedConfig -> SavedConfig -> HUnit.Assertion
isEqual a b = do let check msg f = (HUnit.assertEqual msg `on` f) a b
                 check "globalLocalRepos" (globalLocalRepos . savedGlobalFlags)
                 check "prefix" (show . prefix . savedUserInstallDirs)
                 check "bindir" (show . bindir . savedUserInstallDirs)
                 check "packageDB" (configPackageDB . savedConfigureFlags)
                 check "cache" (globalCacheDir . savedGlobalFlags)

assertProgramOutput :: FilePath -> [String] -> (String -> HUnit.Assertion)
                    -> HUnit.Assertion
assertProgramOutput progPath progArgs check =
    check =<< rawSystemStdout normal progPath progArgs

assertExitsSuccess :: FilePath -> [String] -> HUnit.Assertion
assertExitsSuccess = assertExitStatus (== ExitSuccess)

assertExitsFailure :: FilePath -> [String] -> HUnit.Assertion
assertExitsFailure = assertExitStatus (/= ExitSuccess)

-- XXX: Still dumps output to the terminal
assertExitStatus :: (ExitCode -> Bool) -> FilePath -> [String]
                 -> HUnit.Assertion
assertExitStatus f p args = HUnit.assert . f =<< rawSystem p args

-- Check that this string contains a numeric version
checkNumericVersion :: String -> Either String ()
checkNumericVersion s =
    case lines s of
      [l] -> case simpleParse l of
               Just v  -> let _ = v :: Version
                          in Right ()
               Nothing -> Left $ "Failed to parse version string: " ++ show l
      _   -> Left $ "Expected exactly one line. got: " ++ show s

-- Generate a minimal cabal file for a given package identifier
genCabalFile :: PackageIdentifier -> String
genCabalFile pId =
    unlines
    [ "Name:                " ++ display (pkgName pId)
    , "Version:             " ++ display (pkgVersion pId)
    , "Build-type:          Simple"
    , "Cabal-version:       >=1.2"
    , "Maintainer: nobody"
    , "Description: This package contains no source code, and only enough in\
      \ the Cabal file to make it buildable"
    , "Category: Testing"
    , "License: BSD3"
    , "Synopsis: The most minimal package that will build"
    , "Library"
    , "  build-depends: base"
    ]

-- |Generate a random Cabal package identifier
mkRandomPkgId :: RandomGen g => Rand g PackageIdentifier
mkRandomPkgId = PackageIdentifier <$> getRandomName <*> getRandomVersion
    where
      getRandomVersion = Version <$> getRandomBranch <*> pure tags
          where tags = []

      -- A branch is a version number
      getRandomBranch = do
       n <- getRandomR (1, 5)
       replicateM n $ getRandomR (0, 5000)

      getRandomName = do
        i <- getRandomR (1, 5)
        segs <- replicateM i getRandomSegment
        return $ PackageName $ intercalate "-" segs

      -- A Cabal package name segment must be at least one character
      -- long, consist of alphanumeric characters, and contain at
      -- least one letter.
      getRandomSegment = do
        aChar <- getRandomChar pkgLetter
        before <- getRandomStr pkgChar 10
        after <- getRandomStr pkgChar 10
        return $ before ++ [aChar] ++ after

      -- Given a predicate, select a random character from the first
      -- 256 characters that satsifies that predicate. An exception
      -- will be raised if no character matches the predicate.
      getRandomChar p = do
        let rng = filter p ['\0'..'\255']
        i <- getRandomR (0, length rng - 1)
        return $ rng !! i

      -- Get a random string of characters that match the predicate p
      -- of length [0..n]
      getRandomStr p n = do
        i <- getRandomR (0, n)
        replicateM i $ getRandomChar p

      pkgLetter c = isAscii c && isLetter c

      pkgChar c = isAscii c && isAlphaNum c

addSourceStaysSandboxed :: Verbosity -> FilePath -> FilePath -> HUnit.Assertion
addSourceStaysSandboxed v cabalDev dirName =
    withTempPackage v dirName $ \readPackageIndex packageDir sb pId -> do
      let pkgStr = display pId
      sbPkgs <- readPackageIndex (privateStack sb)
      gPkgs <- readPackageIndex globalStack
      -- XXX: Cabal returns a single "empty" package if you try to
      -- read an empty package db
      let s = filter ((/= "") . display) .
              map installedPackageId .
              allPackages
      HUnit.assertEqual
               "Newly created package index should be empty"
               (s gPkgs) (s sbPkgs)

      let withCabalDev f aa = do
            f cabalDev (["-s", sandbox sb] ++ aa)

      -- Fails because the package is not available. XXX: this
      -- could fail if our randomly chosen filename is available on
      -- hackage. We should actually use a cabal-install config
      -- with an empty package index
      withCabalDev assertExitsFailure ["install", pkgStr]

      withCabalDev assertExitsSuccess ["add-source", packageDir]

      -- Do the installation. Now this library should be registered
      -- with GHC
      withCabalDev assertExitsSuccess
                       ["install", pkgStr, "--verbose=" ++ showForCabal v]

      -- Check that we can find the library in our private package db stack
      pkgIdx' <- readPackageIndex (privateStack sb)
      info v $ dumpIndex pkgIdx'
      case lookupSourcePackageId pkgIdx' pId of
        []  -> HUnit.assertFailure $
               "After installation, package " ++ pkgStr ++ " was not found"
        [_] -> return ()
        _   -> HUnit.assertFailure $
               "Unexpectedly got more than one match for " ++ pkgStr

      -- And that we can't find it in the shared package db stack
      sharedIdx <- readPackageIndex sharedStack
      info v $ dumpIndex sharedIdx
      case lookupSourcePackageId sharedIdx pId of
        []  -> return ()
        _   -> HUnit.assertFailure $
               "Found " ++ pkgStr ++ " in a shared package db!"
    where
      -- The package dbs that cabal-dev will consult
      privateStack sb = [GlobalPackageDB, SpecificPackageDB $ pkgConf sb]

      globalStack = [GlobalPackageDB]

assertLogLocationOk :: Verbosity -> FilePath -> HUnit.Assertion
assertLogLocationOk v cabalDev =
    mapM_ setupLogs [ const $ return ()
                    , createDirectory
                    , (`writeFile` "bogus log data")
                    ]
    where
      setupLogs act =
          withTempPackage v "check-build-log" $ \_ packageDir sb pId -> do
            let pkgStr = display pId
            let withCabalDev f aa = do
                  f cabalDev (["-s", sandbox sb] ++ aa)
            act $ sandbox sb </> "logs"
            putStrLn "BEFORE"
            rawSystem "ls" ["-ld", sandbox sb </> "logs"]
            withCabalDev assertExitsSuccess ["add-source", packageDir]
            withCabalDev assertExitsSuccess ["install", pkgStr]
            -- Do it again to make sure the state hasn't messed it up
            withCabalDev assertExitsSuccess ["install", pkgStr]
            putStrLn "AFTER"
            rawSystem "ls" ["-ld", sandbox sb </> "logs"]
            return ()

-- A human-readable package index dump
dumpIndex :: PackageIndex -> String
dumpIndex pkgIdx = unlines $ "Package index contents:":
                   map (showString "  " . display . packageId)
                   (allPackages pkgIdx)

-- Return a program database containing the programs we need to
-- load a package index
configurePrerequisites :: Verbosity -> IO ProgramConfiguration
configurePrerequisites v =
    configureAllKnownPrograms v $
    addKnownPrograms toConfigure emptyProgramConfiguration
    where
      -- The programs that need to be configured in order to load a
      -- package index
      toConfigure = [ ghcPkgProgram
                    , ghcProgram
                    ]

-- The package dbs that we do not want to pollute
sharedStack :: [PackageDB]
sharedStack = [GlobalPackageDB, UserPackageDB]

-- Given a package index, generate a package name that is not in
-- that index. It is unlikely that a randomly generated name
-- will be in the package index, but we will try three times to
-- make it wildly unlikely.
findUnusedPackageId :: Verbosity -> PackageIndex -> IO PackageIdentifier
findUnusedPackageId v pkgIdx = go []
    where
      go ps = do
        when (length ps > 2) $ HUnit.assertFailure $
             showString "Failed to find an unused package id. Tried:" $
             intercalate " " $
             map display ps

        pId <- evalRandIO mkRandomPkgId
        case searchByName pkgIdx (display $ packageName pId) of
          None -> do info v $ "Found unused package " ++ display pId
                     return pId
          _    -> go (pId:ps)

withTempPackage
    :: Verbosity -> String
    -> (([PackageDB] -> IO PackageIndex)
        -> FilePath
        -> Sandbox KnownVersion -> PackageIdentifier -> HUnit.Assertion)
    -> HUnit.Assertion
withTempPackage v dirName f =
    do pConf <- configurePrerequisites v
       let readPackageIndex stack = getInstalledPackages v stack pConf

       -- Get the shared package index and choose a package identifier
       -- that is not in it
       pkgIdx <- readPackageIndex sharedStack
       info v $ dumpIndex pkgIdx
       pId <- findUnusedPackageId v pkgIdx

       -- Create a temporary directory in which to build and install
       -- the bogus package
       tmp <- getTemporaryDirectory
       withTempDirectory v tmp dirName $ \d -> do
         let sandboxDir = d </> "cabal-dev"
         let packageDir = d </> "pkg"
         let cabalFileName = packageDir </> display (pkgName pId) <.> "cabal"
         createDirectory packageDir
         writeFile cabalFileName $ genCabalFile pId

         sb <- initPkgDb v =<< newSandbox v sandboxDir
         f readPackageIndex packageDir sb pId
