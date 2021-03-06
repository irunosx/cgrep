--
-- Copyright (c) 2012-2013 Bonelli Nicola <bonelli@antifork.org>
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the StopNerds Public License as published by
-- the StopNerds Foundation; either version 1 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- StopNerds Public License for more details.
--
-- You should have received a copy of the StopNerds Public License
-- along with this program; if not, see <http://stopnerds.org/license/>.
--

{-# LANGUAGE ViewPatterns, MagicHash, BangPatterns #-}

module CGrep.Filter (Context(..), ContextFilter(..), contextFilter, mkContextFilter)  where

import CGrep.Common (Text8)

import CGrep.Context
import CGrep.Lang
import Options

import Data.Char
import Data.Array.Unboxed

import qualified Data.ByteString.Char8 as C

import qualified Data.Map as Map

#ifdef __GLASGOW_HASKELL__

import GHC.Prim
import GHC.Exts

#endif


type FilterFunction = ContextFilter -> Text8 -> Text8


type StringBoundary = (String, String)


data Boundary = Boundary
                {
                    _beg   :: !Text8 ,
                    _end   :: !Text8
                }
                deriving (Show)


data ParConf  =  ParConf
                 {
                    commBound :: [Boundary],
                    litrBound :: [Boundary],
                    bloom     :: UArray Char Bool
                 }

data ParState =  ParState
                 {
                    cxtState  :: !ContextState,
                    display   :: !Bool,
                    skip      :: !Int
                 }
                 deriving (Show)


data ContextState = CodeState | CommState Int | LitrState Int
                        deriving (Show, Eq, Ord)


-- filter Context:
--

mkContextFilter :: Options -> ContextFilter
mkContextFilter opt = if not (code opt || comment opt || literal opt)
                       then ContextFilter { getCode = True, getComment = True,  getLiteral = True }
                       else ContextFilter { getCode = code opt, getComment = comment opt, getLiteral = literal opt }


contextFilter :: Maybe Lang -> ContextFilter -> Text8 -> Text8

contextFilter _ (ContextFilter True True True) txt = txt
contextFilter Nothing _ txt = txt
contextFilter (Just language) filt txt
    | Just fun <- parFunc = fun filt txt
    | otherwise = txt
        where parFunc = Map.lookup language filterFunctionMap


-- contextFilterFun:
--


contextFilterFun :: ParConf -> ContextFilter -> Text8 -> Text8
contextFilterFun conf filt txt =  fst $ C.unfoldrN (C.length txt) (contextFilterImpl conf) (txt, filt, ParState CodeState False 0)


type ParData = (Text8, ContextFilter, ParState)


contextFilterImpl :: ParConf -> ParData ->  Maybe (Char, ParData)
contextFilterImpl _ (C.uncons -> Nothing, _, _)     = Nothing
contextFilterImpl c (C.uncons -> Just (x,xs), f, s) = Just (c', (xs, f, s'))
    where !s' = nextContextState c s (x,xs) f
          !c' = if display s' || isSpace x then x else ' '
contextFilterImpl _ _ = undefined


{-# INLINE displayContext #-}

displayContext :: ContextState -> ContextFilter -> Bool
displayContext  CodeState     (ContextFilter b _ _ ) = b
displayContext  (CommState _) (ContextFilter _ b _ ) = b
displayContext  (LitrState _) (ContextFilter _ _ b ) = b


nextContextState :: ParConf -> ParState -> (Char,Text8) -> ContextFilter -> ParState
nextContextState c s (x,xs) filt@(ContextFilter codefilt commfilt litrfilt)
    | skip s > 0                = s { skip = skip s - 1 }
    | x == '\'' && C.pack "\"'" `C.isPrefixOf` xs = s { skip = 2 }
    | x == '\\'                 = s { display = displayContext (cxtState s) filt, skip = 1 }

    | CodeState   <- cxtState s = let cindex = findBoundary (x,xs) (commBound c)
                                      lindex = findBoundary (x,xs) (litrBound c)
                                  in if bloom c ! x
                                     then

                                         if cindex >= 0
                                         then s{ cxtState = CommState cindex, display = codefilt, skip = C.length ( _beg (commBound c !! cindex) ) - 1 }
                                         else if lindex >= 0
                                         then s{ cxtState = LitrState lindex, display = codefilt, skip = C.length ( _beg (litrBound c !! lindex) ) - 1 }
                                         else s{ display  = codefilt, skip = 0 }

                                     else s{ display  = codefilt, skip = 0 }

    | CommState n <- cxtState s = let Boundary _ e = commBound c !! n
                                  in if C.head e == x && C.tail e `C.isPrefixOf` xs
                                     then s{ cxtState = CodeState, display = codefilt, skip = C.length e - 1}
                                     else s{ display  = commfilt, skip = 0 }

    | LitrState n <- cxtState s = let Boundary _ e = litrBound c !! n
                                  in if C.head e == x && C.tail e `C.isPrefixOf` xs
                                     then s{ cxtState = CodeState, display = codefilt, skip = C.length e - 1}
                                     else s{ display = litrfilt, skip = 0 }

nextContextState _ _ (_,_) ContextFilter {} = undefined


{-# INLINE findBoundary #-}

findBoundary :: (Char, Text8) -> [Boundary] -> Int
findBoundary (x,xs) =  findIndex' (\(Boundary b _ ) -> C.head b == x && C.tail b `C.isPrefixOf` xs)


{-# INLINE findIndex' #-}

#ifdef __GLASGOW_HASKELL__

findIndex' :: (a -> Bool) -> [a] -> Int
findIndex' p ls = loop 0# ls
                 where
                   loop _ [] = -1
                   loop n (x:xs) | p x       = I# n
                                 | otherwise = loop (n +# 1#) xs

#else

findIndex' :: (a -> Bool) -> [a] -> Int
findIndex' p = loop 0
                 where
                   loop n [] = -1
                   loop n (x:xs) | p x       = n
                                 | otherwise = loop (n + 1) xs

#endif

-- filter language map:
--

filterFunctionMap :: Map.Map Lang FilterFunction


mkFilterFunction :: [StringBoundary] -> [StringBoundary] -> FilterFunction
mkFilterFunction cs ls = contextFilterFun (ParConf (map (\(a,b) -> Boundary (C.pack a) (C.pack b)) cs)
                                                    (map (\(a,b) -> Boundary (C.pack a) (C.pack b)) ls)
                                                    (mkBloom (cs ++ ls)))


mkBloom :: [StringBoundary] -> UArray Char Bool
mkBloom bs = listArray ('\0', '\255') (map (\c -> findIndex' (\(b,_) -> c == head b) bs >= 0 ) ['\0'..'\255'])


filterFunctionMap = Map.fromList [
    (C,          mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Cpp,        mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Csharp,     mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Chapel,     mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Coffee,     mkFilterFunction [("###", "###"), ("#", "\n")]  [("\"", "\"")] ),
    (D,          mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Go,         mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Java,       mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Javascript, mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (ObjectiveC, mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Scala,      mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (Verilog,    mkFilterFunction [("/*", "*/"), ("//", "\n")]  [("\"", "\"")] ),
    (VHDL,       mkFilterFunction [("--", "\n")] [("\"", "\"")] ),

    (Haskell,    mkFilterFunction [("{-", "-}"), ("--", "\n")]      [("\"", "\""), ("[r|", "|]"), ("[q|", "|]"), ("[s|", "|]"), ("[here|","|]"), ("[i|", "|]")] ),
    (Fsharp,     mkFilterFunction [("(*", "*)"), ("//", "\n")]      [("\"", "\"")] ),
    (Perl,       mkFilterFunction [("=pod", "=cut"), ("#", "\n")]   [("'", "'"), ("\"", "\"")] ),
    (Ruby,       mkFilterFunction [("=begin", "=end"), ("#", "\n")] [("'", "'"), ("\"", "\""), ("%|", "|"), ("%q(", ")"), ("%Q(", ")") ]),

    (CMake,      mkFilterFunction [("#", "\n")]    [("\"", "\"")] ),
    (Awk,        mkFilterFunction [("#", "\n")]    [("\"", "\"")] ),
    (Tcl,        mkFilterFunction [("#", "\n")]    [("\"", "\"")] ),
    (Shell,      mkFilterFunction [("#", "\n")]    [("'", "'"), ("\"", "\"")] ),
    (Make,       mkFilterFunction [("#", "\n")]    [("'", "'"), ("\"", "\"")] ),

    (Css,        mkFilterFunction [("/*", "*/")]   [("\"", "\"")] ),
    (OCaml,      mkFilterFunction [("(*", "*)")]   [("\"", "\"")] ),
    (Python,     mkFilterFunction [("#", "\n")]    [("\"\"\"", "\"\"\""), ("'''", "'''"), ("'", "'"), ("\"", "\"")] ),

    (Erlang,     mkFilterFunction [("%", "\n")]    [("\"", "\"")] ),
    (Latex,      mkFilterFunction [("%", "\n")]    [("\"", "\"")] ),
    (Lua,        mkFilterFunction [("--[[","--]]"), ("--", "\n")]    [("'", "'"), ("\"", "\""), ("[===[", "]===]"), ("[==[", "]==]"), ("[=[", "]=]"), ("[[", "]]") ] ),

    (Html,       mkFilterFunction [("<!--", "-->")]  [("\"", "\"")] ),
    (Vim,        mkFilterFunction [("\"", "\n")]     [("'", "'")] ),

    (PHP,        mkFilterFunction [("/*", "*/"), ("//", "\n"), ("#", "\n") ]  [("'", "'"), ("\"", "\"")] )
    ]

