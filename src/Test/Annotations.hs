{-# LANGUAGE PatternGuards, RecordWildCards, ViewPatterns #-}

-- | Check the <TEST> annotations within source and hint files.
module Test.Annotations(testAnnotations) where

import Control.Exception.Extra
import Data.Tuple.Extra
import Data.Char
import Data.Either.Extra
import Data.List.Extra
import Data.Maybe
import Data.Function

import Config.Type
import Idea
import Apply
import HSE.All
import Test.Util
import Data.Functor
import Prelude


-- Input, Output
-- Output = Nothing, should not match
-- Output = Just xs, should match xs
data Test = Test SrcLoc String (Maybe String)

testAnnotations :: [Setting] -> FilePath -> IO ()
testAnnotations setting file = do
    tests <- parseTestFile file
    mapM_ f tests
    where
        f (Test loc inp out) = do
            ideas <- try_ $ do
                res <- applyHintFile defaultParseFlags setting file $ Just inp
                evaluate $ length $ show res
                return res
            let good = case (out, ideas) of
                    (Nothing, Right []) -> True
                    (Just x, Right [idea]) | match x idea -> True
                    _ -> False
            let bad =
                    [failed $
                        ["TEST FAILURE (" ++ show (either (const 1) length ideas) ++ " hints generated)"
                        ,"SRC: " ++ showSrcLoc loc
                        ,"INPUT: " ++ inp] ++
                        map ("OUTPUT: " ++) (either (return . show) (map show) ideas) ++
                        ["WANTED: " ++ fromMaybe "<failure>" out]
                        | not good] ++
                    [failed
                        ["TEST FAILURE (BAD LOCATION)"
                        ,"SRC: " ++ showSrcLoc loc
                        ,"INPUT: " ++ inp
                        ,"OUTPUT: " ++ show i]
                        | i@Idea{..} <- fromRight [] ideas, let SrcLoc{..} = getPointLoc ideaSpan, srcFilename == "" || srcLine == 0 || srcColumn == 0]
            if null bad then passed else sequence_ bad

        match "???" _ = True
        match (word1 -> ("@Message",msg)) i = ideaHint i == msg
        match (word1 -> ("@Note",note)) i = map show (ideaNote i) == [note]
        match "@NoNote" i = null (ideaNote i)
        match (word1 -> ('@':sev, msg)) i = sev == show (ideaSeverity i) && match msg i
        match msg i = on (==) norm (fromMaybe "" $ ideaTo i) msg

        -- FIXME: Should use a better check for expected results
        norm = filter $ \x -> not (isSpace x) && x /= ';'


parseTestFile :: FilePath -> IO [Test]
parseTestFile file =
    -- we remove all leading # symbols since Yaml only lets us do comments that way
    f False . zip [1..] . map (\x -> fromMaybe x $ stripPrefix "# " x) . lines <$> readFile file
    where
        open = isPrefixOf "<TEST>"
        shut = isPrefixOf "</TEST>"

        f False ((i,x):xs) = f (open x) xs
        f True  ((i,x):xs)
            | shut x = f False xs
            | null x || "-- " `isPrefixOf` x = f True xs
            | "\\" `isSuffixOf` x, (_,y):ys <- xs = f True $ (i,init x++"\n"++y):ys
            | otherwise = parseTest file i x : f True xs
        f _ [] = []


parseTest file i x = uncurry (Test (SrcLoc file i 0)) $ f x
    where
        f x | Just x <- stripPrefix "<COMMENT>" x = first ("--"++) $ f x
        f (' ':'-':'-':xs) | null xs || " " `isPrefixOf` xs = ("", Just $ dropWhile isSpace xs)
        f (x:xs) = first (x:) $ f xs
        f [] = ([], Nothing)
