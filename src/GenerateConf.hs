{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Generate Apache directory protection directives from a config file.
module GenerateConf where

import GHC.Generics (Generic)
import Data.Yaml
import qualified Data.Text as Text
import qualified Data.Char as Char
import qualified Data.List as List
import Control.Monad
import Control.Monad.Reader
import Pipes

-- | Warning when analyzing config file.
type Warning = String

-- | Produce a value while generating warnings along the way;
-- read app config for information.
type App m a = ReaderT (AppConfig m) (Producer Warning m) a

data AppConfig m =
  AppConfig { doc :: Doc
            , goodDir :: FilePath -> m Bool
            }

-- | YAML config file.
data Doc =
  Doc { dirPrefix :: FilePath -- ^ prefix for all real paths
      , passwordDirPrefix :: FilePath -- ^ prefix for password files
      , dirs :: [DirInfo]
      }
  deriving (Show, Generic)

instance FromJSON Doc

-- | Entry for one corpus.
-- Use 'String' for simplicity rather than 'Text'.
data DirInfo =
  DirInfo { dir :: FilePath
          , users :: [String]
          , passwordsFile :: FilePath
          , scope :: [JScopeTag]
          }
  deriving (Show, Generic)

instance FromJSON DirInfo

-- | User directive for which directories should be protected.
-- 'All' means Data, DataOrig, DataXml, Media.
data JScopeTag
  = All
  | Tag ScopeTag
  deriving (Generic)

instance Show JScopeTag where
  show All = "all"
  show (Tag t) = show t

data ScopeTag
  = Verbatim
  | Data
  | DataOrig
  | DataXml
  | Media
  deriving (Enum, Bounded, Generic)

instance Show ScopeTag where
  show Verbatim = "verbatim"
  show Data = "data"
  show DataOrig = "data-orig"
  show DataXml = "data-xml"
  show Media = "media"

invalidScopeTag :: String -> String
invalidScopeTag s =
  "Illegal scope (" ++ s ++ "): must be one of " ++
  show [minBound :: ScopeTag ..] ++
  " or " ++ show All

instance FromJSON JScopeTag where
  parseJSON (String "all") = return All
  parseJSON s = Tag <$> parseJSON s

instance FromJSON ScopeTag where
  parseJSON (String "verbatim") = return Verbatim
  parseJSON (String "data") = return Data
  parseJSON (String "data-orig") = return DataOrig
  parseJSON (String "data-xml") = return DataXml
  parseJSON (String "media") = return Media
  parseJSON (String s) = fail $ invalidScopeTag $ Text.unpack s
  parseJSON x = fail $ invalidScopeTag $ show x

-- | Representation of a single Apache directive.
-- realDir is relative to the doc root.
data Directive = Directive { label :: String
                           , realDir :: FilePath
                           , users1 :: [String]
                           , passwordsFile1 :: FilePath
                           }
                 deriving (Show)

-- | Absolute directory path.
absoluteDir :: Doc -> Directive -> String
absoluteDir theDoc d = dirPrefix theDoc ++ "/" ++ realDir d

-- | Simple-minded, rather than with a template engine.
formatDirective :: Doc -> Directive -> String
formatDirective theDoc d =
  unlines [ "# " ++ absoluteDir theDoc d
          , "<Directory \"" ++ caseInsensitive (absoluteDir theDoc d) ++ "/\">"
          , "  Options Includes Indexes FollowSymLinks MultiViews"
          , "  AllowOverride None"
          , "  AuthType Basic"
          , "  AuthName \"Password protected data for " ++ label d ++ "\""
          , "  AuthUserFile " ++ passwordDirPrefix theDoc ++ "/" ++ passwordsFile1 d
          , "  Require user " ++ List.intercalate " " (users1 d)
          , "</Directory>"
          ]

-- | Convert into case-insensitive regex.
--
-- >>> caseInsensitive "/foo/Bar/CamelCase/"
-- "/[Ff][Oo][Oo]/[Bb][Aa][Rr]/[Cc][Aa][Mm][Ee][Ll][Cc][Aa][Ss][Ee]/"
caseInsensitive :: String -> String
caseInsensitive = concatMap replaceChar

-- | Replace letter with regex.
--
-- >>> replaceChar 'o'
-- "[Oo]"
--
-- >>> replaceChar 'A'
-- "[Aa]"
--
-- >>> replaceChar '/'
-- "/"
replaceChar :: Char -> String
replaceChar c | Char.isLetter c = ['[', Char.toUpper c, Char.toLower c, ']']
              | otherwise = [c]

-- | May generate multiple directives.
generateDirectives :: Monad m => DirInfo -> App m [Directive]
generateDirectives info =
  traverse (generateDirective info) (realScopes (scope info))

-- | Generate directive for a single real scope.
generateDirective :: Monad m => DirInfo -> ScopeTag -> App m Directive
generateDirective info s = do
  path <- checkDirectory (dir info) s
  return $ Directive (dir info) path (users info) (passwordsFile info)

-- | Check existence of directories and warn if nonexistent but
-- keep going anyway.
checkDirectory :: Monad m => FilePath -> ScopeTag -> App m FilePath
checkDirectory d s = do
  AppConfig theDoc checkGoodDir <- ask
  let relDir = realDirectory d s
  let path = dirPrefix theDoc ++ "/" ++ relDir
  exists <- lift $ lift $ checkGoodDir path
  unless exists $
    lift $ yield $ "###### Warning: " ++ path ++ " does not exist!"
  return relDir

-- | Compute the (relative) real directory being protected.
realDirectory :: FilePath -> ScopeTag -> FilePath
realDirectory d Verbatim = d
realDirectory d DataOrig = "data-orig/" ++ d
realDirectory d Data = "data/" ++ d
realDirectory d DataXml = "data-xml/" ++ d
realDirectory d Media = "media/" ++ d

-- | Compute scopes
realScopes :: [JScopeTag] -> [ScopeTag]
realScopes = concatMap convertScopeTag

-- | 'All' stands for a list of scopes.
convertScopeTag :: JScopeTag -> [ScopeTag]
convertScopeTag All = [DataOrig, Data, DataXml, Media]
convertScopeTag (Tag t) = [t]

-- | Stateful only because of checking directory existence.
formatDirInfo :: Monad m => DirInfo -> App m String
formatDirInfo info = do
  ds <- generateDirectives info
  theDoc <- asks doc
  return $ "### Generated for " ++ dir info ++ "\n" ++
    separateBlocks (formatDirective theDoc <$> ds)

-- | For visual clarity, separate text blocks with a newline.
separateBlocks :: [String] -> String
separateBlocks = List.intercalate "\n"

-- | Return full directive string for the YAML config.
-- Stateful only because of checking directory existence.
directivesOutput :: Monad m => App m String
directivesOutput = do
  theDoc <- asks doc
  separateBlocks <$> traverse formatDirInfo (dirs theDoc)

-- | Return all relative directories to be protected.
relativeDirsOutput :: Monad m => App m String
relativeDirsOutput = do
  theDoc <- asks doc
  separateBlocks <$> traverse relativeDirInfo (dirs theDoc)

relativeDirInfo :: Monad m => DirInfo -> App m String
relativeDirInfo info = do
  ds <- generateDirectives info
  return $ separateBlocks (realDir <$> ds)
