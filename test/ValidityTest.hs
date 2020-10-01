{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- | Test suite.
module Main where

import Control.Applicative
import Control.Monad
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Either
import Path
import Path.Internal
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import Test.Validity

import Path.Gen

-- | Test suite entry point, returns exit failure if any test fails.
main :: IO ()
main = hspec spec

-- | Test suite.
spec :: Spec
spec =
  modifyMaxShrinks (const 100) $
  parallel $ do
    genValidSpec @(Path Abs File)
    shrinkValidSpec @(Path Abs File)
    genValidSpec @(Path Rel File)
    shrinkValidSpec @(Path Rel File)
    genValidSpec @(Path Abs Dir)
    shrinkValidSpec @(Path Abs Dir)
    genValidSpec @(Path Rel Dir)
    shrinkValidSpec @(Path Rel Dir)
    describe "Parsing" $ do
      describe "Path Abs Dir" (parserSpec (either (const Nothing) Just . parseAbsDir))
      describe "Path Rel Dir" (parserSpec (either (const Nothing) Just . parseRelDir))
      describe "Path Abs File" (parserSpec (either (const Nothing) Just . parseAbsFile))
      describe "Path Rel File" (parserSpec (either (const Nothing) Just . parseRelFile))
    describe "Operations" $ do
      describe "(</>)" operationAppend
      describe "stripProperPrefix" operationStripDir
      describe "isProperPrefixOf" operationIsParentOf
      describe "parent" operationParent
      describe "filename" operationFilename
      describe "dirname" operationDirname
    describe "Extensions" extensionsSpec

-- | The 'filename' operation.
operationFilename :: Spec
operationFilename = do
  forAllDirs "filename parent </> $(mkRelFile filename)) == filename $(mkRelFile filename)" $ \parent ->
    forAllValid $ \file -> filename (parent </> file) `shouldBe` filename file
  it "produces a valid path on when passed a valid absolute path" $ do
    producesValidsOnValids (filename :: Path Abs File -> Path Rel File)
  it "produces a valid path on when passed a valid relative path" $ do
    producesValidsOnValids (filename :: Path Rel File -> Path Rel File)

-- | The 'dirname' operation.
operationDirname :: Spec
operationDirname = do
  forAllDirs "dirname parent </> $(mkRelDir dirname)) == dirname $(mkRelDir dirname)" $ \parent ->
    forAllValid $ \dir -> if dir == Path [] then pure () else dirname (parent </> dir) `shouldBe` dirname dir
  it "produces a valid path on when passed a valid absolute path" $ do
    producesValidsOnValids (dirname :: Path Abs Dir -> Path Rel Dir)
  it "produces a valid path on when passed a valid relative path" $ do
    producesValidsOnValids (dirname :: Path Rel Dir -> Path Rel Dir)

-- | The 'parent' operation.
operationParent :: Spec
operationParent = do
  it "produces a valid path on when passed a valid file path" $ do
    producesValidsOnValids (parent :: Path Abs File -> Path Abs Dir)
  it "produces a valid path on when passed a valid directory path" $ do
    producesValidsOnValids (parent :: Path Abs Dir -> Path Abs Dir)

-- | The 'isProperPrefixOf' operation.
operationIsParentOf :: Spec
operationIsParentOf = do
  forAllParentsAndChildren "isProperPrefixOf parent (parent </> child)" $ \parent child ->
    if child == Path []
      then True -- TODO do we always need this condition?
      else isProperPrefixOf parent (parent </> child)

-- | The 'stripProperPrefix' operation.
operationStripDir :: Spec
operationStripDir = do
  forAllParentsAndChildren "stripProperPrefix parent (parent </> child) = child" $ \parent child ->
    if child == Path []
      then pure () -- TODO do we always need this condition?
      else stripProperPrefix parent (parent </> child) `shouldSatisfy` either (const False) (== child)
  it "produces a valid path on when passed a valid absolute file paths" $ do
    producesValidsOnValids2
      ((either (const Nothing) Just .) . stripProperPrefix :: Path Abs Dir -> Path Abs File -> Maybe (Path Rel File))
  it "produces a valid path on when passed a valid absolute directory paths" $ do
    producesValidsOnValids2
      ((either (const Nothing) Just .) . stripProperPrefix :: Path Abs Dir -> Path Abs Dir -> Maybe (Path Rel Dir))
  it "produces a valid path on when passed a valid relative file paths" $ do
    producesValidsOnValids2
      ((either (const Nothing) Just .) . stripProperPrefix :: Path Rel Dir -> Path Rel File -> Maybe (Path Rel File))
  it "produces a valid path on when passed a valid relative directory paths" $ do
    producesValidsOnValids2
      ((either (const Nothing) Just .) . stripProperPrefix :: Path Rel Dir -> Path Rel Dir -> Maybe (Path Rel Dir))

-- | The '</>' operation.
operationAppend :: Spec
operationAppend = do
  it "produces a valid path on when creating valid absolute file paths" $ do
    producesValidsOnValids2 ((</>) :: Path Abs Dir -> Path Rel File -> Path Abs File)
  it "produces a valid path on when creating valid absolute directory paths" $ do
    producesValidsOnValids2 ((</>) :: Path Abs Dir -> Path Rel Dir -> Path Abs Dir)
  it "produces a valid path on when creating valid relative file paths" $ do
    producesValidsOnValids2 ((</>) :: Path Rel Dir -> Path Rel File -> Path Rel File)
  it "produces a valid path on when creating valid relative directory paths" $ do
    producesValidsOnValids2 ((</>) :: Path Rel Dir -> Path Rel Dir -> Path Rel Dir)

extensionsSpec :: Spec
extensionsSpec = do
  it "if addExtension a b succeeds then parseRelFile b succeeds - 1" $
    forAll genFilePath addExtGensValidFile
     -- skew the generated path towards a valid extension by prefixing a "."
  it "if addExtension a b succeeds then parseRelFile b succeeds - 2" $
    forAll genFilePath $ addExtGensValidFile . ("." ++)
  forAllFiles
    "(fmap toFilePath . addExtension ext) file \
        \== Right (toFilePath a ++ b)" $ \file ->
    forAllValid $ \(Extension ext) ->
      (fmap toFilePath . addExtension ext) file `shouldSatisfy` either (const False) (== toFilePath file ++ ext)
  forAllFiles "splitExtension output joins to result in the original file" $ \file ->
    case splitExtension file of
      Left _ -> pure ()
      Right (f, ext) -> toFilePath f ++ ext `shouldBe` toFilePath file
  forAllFiles "splitExtension generates a valid filename and valid extension" $ \file ->
    case splitExtension file of
      Left _ -> True
      Right (f, ext) ->
        case parseRelFile ext of
          Left _ -> False
          Right _ ->
            case parseRelFile (toFilePath f) of
              Left _ -> isRight $ parseAbsFile (toFilePath f)
              Right _ -> True
  forAllFiles "splitExtension >=> uncurry addExtension . swap == return" $ \file ->
    case splitExtension file of
      Left _ -> pure ()
      Right (f, ext) -> addExtension ext f `shouldSatisfy` either (const False) (== file)
  forAllFiles "uncurry addExtension . swap >=> splitExtension == return" $ \file ->
    forAllValid $ \(Extension ext) ->
      (addExtension ext file >>= splitExtension) `shouldSatisfy` either (const False) (== (file, ext))
  forAllFiles "fileExtension == (fmap snd) . splitExtension" $ \file ->
    case splitExtension file of
      Left _ -> pure ()
      Right (_, ext) -> fileExtension file `shouldSatisfy` either (const False) (== ext)
  forAllFiles "flip addExtension file >=> fileExtension == return" $ \file ->
    forAllValid $ \(Extension ext) ->
      (fileExtension <=< addExtension ext) file `shouldSatisfy` either (const False) (== ext)
  forAllFiles "(fileExtension >=> flip replaceExtension file) file == return file" $ \file ->
    case fileExtension file of
      Left _ -> pure ()
      Right ext -> replaceExtension ext file `shouldSatisfy` either (const False) (== file)
  where
    addExtGensValidFile p =
      case addExtension p $(mkRelFile "x") of
        Left _ -> True
        Right x -> isRight $ parseRelFile p

forAllFiles :: Testable a => String -> (forall b. Path b File -> a) -> Spec
forAllFiles n func = do
  it (unwords [n, "Path Abs File"]) $ forAllValid $ \(file :: Path Abs File) -> func file
  it (unwords [n, "Path Rel File"]) $ forAllValid $ \(file :: Path Rel File) -> func file

forAllDirs :: Testable a => String -> (forall b. Path b Dir -> a) -> Spec
forAllDirs n func = do
  it (unwords [n, "Path Abs Dir"]) $ forAllValid $ \(parent :: Path Abs Dir) -> func parent
  it (unwords [n, "Path Rel Dir"]) $ forAllValid $ \(parent :: Path Rel Dir) -> func parent

forAllParentsAndChildren ::
     Testable a => String -> (forall b t. Path b Dir -> Path Rel t -> a) -> Spec
forAllParentsAndChildren n func = do
  it (unwords [n, "Path Abs Dir", "Path Rel Dir"]) $
    forAllValid $ \(parent :: Path Abs Dir) ->
      forAllValid $ \(child :: Path Rel Dir) -> func parent child
  it (unwords [n, "Path Rel Dir", "Path Rel Dir"]) $
    forAllValid $ \(parent :: Path Rel Dir) ->
      forAllValid $ \(child :: Path Rel Dir) -> func parent child
  it (unwords [n, "Path Abs Dir", "Path Rel File"]) $
    forAllValid $ \(parent :: Path Abs Dir) ->
      forAllValid $ \(child :: Path Rel File) -> func parent child
  it (unwords [n, "Path Rel Dir", "Path Rel File"]) $
    forAllValid $ \(parent :: Path Rel Dir) ->
      forAllValid $ \(child :: Path Rel File) -> func parent child

forAllPaths :: Testable a => String -> (forall b t. Path b t -> a) -> Spec
forAllPaths n func = do
  it (unwords [n, "Path Abs Dir"]) $ forAllValid $ \(path :: Path Abs Dir) -> func path
  it (unwords [n, "Path Rel Dir"]) $ forAllValid $ \(path :: Path Rel Dir) -> func path
  it (unwords [n, "Path Abs File"]) $ forAllValid $ \(path :: Path Abs File) -> func path
  it (unwords [n, "Path Rel File"]) $ forAllValid $ \(path :: Path Rel File) -> func path

parserSpec :: (Show p, Validity p) => (FilePath -> Maybe p) -> Spec
parserSpec parser =
  it "Produces valid paths when it succeeds" $
  forAllShrink genFilePath shrinkUnchecked $ \path ->
    case parser path of
      Nothing -> pure ()
      Just p ->
        case prettyValidate p of
          Left err -> expectationFailure err
          Right _ -> pure ()
