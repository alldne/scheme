{-# LANGUAGE ExistentialQuantification, FlexibleContexts #-}

module Scheme.Evaluator
  ( evalString
  , newEnv
  , runRepl
  , runOne
  ) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.IORef
import Data.Maybe
import System.Console.Haskeline
import System.IO

import Scheme.Desugarer
import Scheme.Parser
import Scheme.Types

liftThrows :: ThrowsError a -> EvalM a
liftThrows (Left err) = EvalM $ lift $ throwError err
liftThrows (Right val) = EvalM $ lift $ return val

-- FIXME: Add let
eval :: LispVal -> EvalM LispVal
eval val@(String _) = return val
eval val@(Number _) = return val
eval val@(Bool _) = return val
eval (Atom id) = getVar id
eval (List (Atom "begin" : exps)) = fmap last $ mapM eval exps
eval (List [Atom "quote", val]) = return val
-- FIXME: Make alt optional
eval (List [Atom "if", pred, conseq, alt]) = do
    result <- eval pred
    case result of
        Bool False -> eval alt
        otherwise -> eval conseq
eval (List [Atom "set!", Atom var, form]) =
    eval form >>= setVar var
eval (List [Atom "define", Atom var, form]) =
    eval form >>= defineVar var
eval (List (Atom "define" : List (Atom var : params) : body)) =
    makeNormalFunc params body >>= defineVar var
eval (List (Atom "define" : DottedList (Atom var : params) varargs : body)) =
    makeVarargs varargs params body >>= defineVar var
eval (List (Atom "lambda" : List params : body)) =
    makeNormalFunc params body
eval (List (Atom "lambda" : DottedList params varargs : body)) =
    makeVarargs varargs params body
eval (List (Atom "lambda" : varargs@(Atom _) : body)) =
    makeVarargs varargs [] body
eval (List [Atom "load", String filename]) =
    (load filename) >>= fmap last . mapM (eval . desugar)
eval (List (function : args)) = do
    func <- eval function
    argVals <- mapM eval args
    apply func argVals
eval badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm

apply :: LispVal -> [LispVal] -> EvalM LispVal
apply (PrimitiveFunc func) args = liftThrows $ func args
apply (Func params varargs body closure) args =
    if num params /= num args && varargs == Nothing
       then throwError $ NumArgs (num params) args
       else do
           env <- (liftIO $ bindVars closure $ zip params args)
           env' <- bindVarArgs varargs env
           local (const env') evalBody
    where remainingArgs = drop (length params) args
          num = toInteger . length
          evalBody = fmap last $ mapM eval body
          bindVarArgs arg env = case arg of
              Just argName -> liftIO $ bindVars env [(argName, List $ remainingArgs)]
              Nothing -> return env

primitives :: [(String, [LispVal] -> ThrowsError LispVal)]
primitives = [("+", numericBinop (+)),
              ("-", numericBinop (-)),
              ("*", numericBinop (*)),
              ("/", numericBinop div),
              ("mod", numericBinop mod),
              ("quotient", numericBinop quot),
              ("remainder", numericBinop rem),
              ("=", numBoolBinop (==)),
              ("<", numBoolBinop (<)),
              (">", numBoolBinop (>)),
              ("/=", numBoolBinop (/=)),
              (">=", numBoolBinop (>=)),
              ("<=", numBoolBinop (<=)),
              ("&&", boolBoolBinop (&&)),
              ("||", boolBoolBinop (||)),
              ("string=?", strBoolBinop (==)),
              ("string<?", strBoolBinop (<)),
              ("string>?", strBoolBinop (>)),
              ("string<=?", strBoolBinop (<=)),
              ("string>=?", strBoolBinop (>=)),
              ("car", car),
              ("cdr", cdr),
              ("cons", cons),
              ("eq?", eqv),
              ("eqv?", eqv),
              ("equal?", equal),
              -- FIXME: Add char?, vector?
              ("boolean?", isBoolean),
              ("pair?", isPair),
              ("symbol?", isSymbol),
              ("number?", isNumber),
              ("string?", isString),
              ("port?", isPort),
              ("procedure?", isProcedure)]

numericBinop :: (Integer -> Integer -> Integer) -> [LispVal] -> ThrowsError LispVal
numericBinop op singleVal@[_] = throwError $ NumArgs 2 singleVal
numericBinop op params = mapM unpackNum params >>= return . Number . foldl1 op

boolBinop :: (LispVal -> ThrowsError a) -> (a -> a -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBinop unpacker op args = if length args /= 2
                             then throwError $ NumArgs 2 args
                             else do left <- unpacker $ args !! 0
                                     right <- unpacker $ args !! 1
                                     return $ Bool $ left `op` right

numBoolBinop :: (Integer -> Integer -> Bool) -> [LispVal] -> ThrowsError LispVal
numBoolBinop = boolBinop unpackNum

strBoolBinop :: (String -> String -> Bool) -> [LispVal] -> ThrowsError LispVal
strBoolBinop = boolBinop unpackStr

boolBoolBinop :: (Bool -> Bool -> Bool) -> [LispVal] -> ThrowsError LispVal
boolBoolBinop = boolBinop unpackBool

unpackNum :: LispVal -> ThrowsError Integer
unpackNum (Number n) = return n
unpackNum (String n) = let parsed = reads n in
                          if null parsed
                            then throwError $ TypeMismatch "number" $ String n
                            else return $ fst $ parsed !! 0
unpackNum (List [n]) = unpackNum n
unpackNum notNum = throwError $ TypeMismatch "number" notNum

unpackStr :: LispVal -> ThrowsError String
unpackStr (String s) = return s
unpackStr (Number s) = return $ show s
unpackStr (Bool s) = return $ show s
unpackStr notString = throwError $ TypeMismatch "string" notString

unpackBool :: LispVal -> ThrowsError Bool
unpackBool (Bool b) = return b
unpackBool notBool = throwError $ TypeMismatch "boolean" notBool

car :: [LispVal] -> ThrowsError LispVal
car [List (x : xs)] = return x
car [DottedList (x : xs) _] = return x
car [badArg] = throwError $ TypeMismatch "pair" badArg
car badArgList = throwError $ NumArgs 1 badArgList

cdr :: [LispVal] -> ThrowsError LispVal
cdr [List (x : xs)] = return $ List xs
cdr [DottedList (_ : xs) x] = return $ DottedList xs x
cdr [DottedList [xs] x] = return x
cdr [badArg] = throwError $ TypeMismatch "pair" badArg
cdr badArgList = throwError $ NumArgs 1 badArgList

cons :: [LispVal] -> ThrowsError LispVal
cons [x1, List []] = return $ List [x1]
cons [x, List xs] = return $ List $ x : xs
cons [x, DottedList xs xlast] = return $ DottedList (x : xs) xlast
cons [x1, x2] = return $ DottedList [x1] x2
cons badArgList = throwError $ NumArgs 2 badArgList

eqv :: [LispVal] -> ThrowsError LispVal
eqv [arg1, arg2] = return . Bool $ arg1 == arg2
eqv badArgList = throwError $ NumArgs 2 badArgList

isBoolean :: [LispVal] -> ThrowsError LispVal
isBoolean [(Bool _)] = return . Bool $ True
isBoolean [_]= return . Bool $ False
isBoolean badArgList = throwError $ NumArgs 1 badArgList

isPair :: [LispVal] -> ThrowsError LispVal
isPair [List (x:y:_)] = return . Bool $ True
isPair [DottedList _ _] = return . Bool $ True
isPair [_]= return . Bool $ False
isPair badArgList = throwError $ NumArgs 1 badArgList

isSymbol :: [LispVal] -> ThrowsError LispVal
isSymbol [Atom _] = return . Bool $ True
isSymbol [_]= return . Bool $ False
isSymbol badArgList = throwError $ NumArgs 1 badArgList

isNumber :: [LispVal] -> ThrowsError LispVal
isNumber [Number _] = return . Bool $ True
isNumber [_]= return . Bool $ False
isNumber badArgList = throwError $ NumArgs 1 badArgList

isString :: [LispVal] -> ThrowsError LispVal
isString [String _] = return . Bool $ True
isString [_]= return . Bool $ False
isString badArgList = throwError $ NumArgs 1 badArgList

isPort :: [LispVal] -> ThrowsError LispVal
isPort [Port _] = return . Bool $ True
isPort [_]= return . Bool $ False
isPort badArgList = throwError $ NumArgs 1 badArgList

isProcedure :: [LispVal] -> ThrowsError LispVal
isProcedure [PrimitiveFunc _] = return . Bool $ True
isProcedure [IOFunc _] = return . Bool $ True
isProcedure [Func _ _ _ _] = return . Bool $ True
isProcedure [_]= return . Bool $ False
isProcedure badArgList = throwError $ NumArgs 1 badArgList

data Unpacker = forall a. Eq a => AnyUnpacker (LispVal -> ThrowsError a)

unpackEquals :: LispVal -> LispVal -> Unpacker -> ThrowsError Bool
unpackEquals arg1 arg2 (AnyUnpacker unpacker) =
             do unpacked1 <- unpacker arg1
                unpacked2 <- unpacker arg2
                return $ unpacked1 == unpacked2
        `catchError` (const $ return False)

equal :: [LispVal] -> ThrowsError LispVal
equal [arg1, arg2] = do
    primitiveEquals <- fmap or $ mapM (unpackEquals arg1 arg2)
                      [AnyUnpacker unpackNum, AnyUnpacker unpackStr, AnyUnpacker unpackBool]
    eqvEquals <- eqv [arg1, arg2]
    return $ Bool $ (primitiveEquals || let (Bool x) = eqvEquals in x)
equal badArgList = throwError $ NumArgs 2 badArgList

evalString :: Env -> String -> IO (Either LispError LispVal)
evalString env expr =
    let evalResult = (liftThrows $ readExpr expr) >>= eval . desugar :: EvalM LispVal
    in
        runEvalM env evalResult

until_ :: Monad m => (a -> Bool) -> m a -> (a -> m ()) -> m ()
until_ pred prompt action = do
  result <- prompt
  if pred result
     then return ()
     else action result >> until_ pred prompt action

-- FIXME: Load stdlib.scm before evaluating the program
runOne :: [String] -> IO ()
runOne args = do
    env <- newEnv >>= flip bindVars [("args", List $ map String $ drop 1 args)]
    (runEvalM env $ eval (List [Atom "load", String (args !! 0)]))
         >>= hPutStrLn stderr . (either show show)

runRepl :: IO ()
runRepl = runInputT defaultSettings replLoop

replLoop :: InputT IO ()
replLoop = do
    env <- liftIO newEnv
    until_ quitPred (getInputLine "Lisp>>> ") (evalAndPrint env . fromJust)
  where
    quitPred Nothing = True
    quitPred (Just "quit") = True
    quitPred _ = False

    evalAndPrint env expr = do
      evalResult <- liftIO $ evalString env expr
      outputStrLn $ either show show evalResult

nullEnv :: IO Env
nullEnv = newIORef []

newEnv :: IO Env
newEnv = primitiveBindings
  where
    makeFunc constructor (var, func) = (var, constructor func)

    primitiveBindings :: IO Env
    primitiveBindings = nullEnv >>= (flip bindVars $ map (makeFunc IOFunc) ioPrimitives
                                              ++ map (makeFunc PrimitiveFunc) primitives)

runEvalM :: Env -> EvalM LispVal -> IO (Either LispError LispVal)
runEvalM env action = runExceptT ioThrows
    where ioThrows = (runReaderT . run) action $ env

isBound :: Env -> String -> IO Bool
isBound envRef var = readIORef envRef >>= return . maybe False (const True) . lookup var

getVar :: String -> EvalM LispVal
getVar var  =  do
    envRef <- ask
    env <- liftIO $ readIORef envRef
    maybe (throwError $ UnboundVar "Getting an unbound variable" var)
                             (liftIO . readIORef)
                             (lookup var env)

setVar :: String -> LispVal -> EvalM LispVal
setVar var value = do
    envRef <- ask
    env <- liftIO $ readIORef envRef
    maybe (throwError $ UnboundVar "Setting an unbound variable" var)
        (liftIO . (flip writeIORef value))
        (lookup var env)
    return value

defineVar :: String -> LispVal -> EvalM LispVal
defineVar var value = do
    envRef <- ask
    alreadyDefined <- liftIO $ isBound envRef var
    if alreadyDefined
       then setVar var value >> return value
       else liftIO $ do
          valueRef <- newIORef value
          env <- readIORef envRef
          writeIORef envRef ((var, valueRef) : env)
          return value

bindVars :: Env -> [(String, LispVal)] -> IO Env
bindVars envRef bindings = readIORef envRef >>= extendEnv bindings >>= newIORef
    where extendEnv bindings env = fmap (++ env) (mapM addBinding bindings)
          addBinding (var, value) = do ref <- newIORef value
                                       return (var, ref)

makeFunc :: Maybe String -> [LispVal] -> [LispVal] -> EvalM LispVal
makeFunc varargs params body = do
  env <- ask
  return $ Func (map showVal params) varargs body env

makeNormalFunc :: [LispVal] -> [LispVal] -> EvalM LispVal
makeNormalFunc = makeFunc Nothing

makeVarargs :: LispVal -> [LispVal] -> [LispVal] -> EvalM LispVal
makeVarargs = makeFunc . Just . showVal

-- FIXME: Add more IO primitives
ioPrimitives :: [(String, [LispVal] -> EvalM LispVal)]
ioPrimitives = [("apply", applyProc),
                ("open-input-file", makePort ReadMode),
                ("open-output-file", makePort WriteMode),
                ("close-input-port", closePort),
                ("close-output-port", closePort),
                ("read", readProc),
                ("write", writeProc),
                ("read-contents", readContents),
                ("read-all", readAll)]
-- FIXME: Add display function which prints the value to the stdout

applyProc :: [LispVal] -> EvalM LispVal
applyProc [func, List args] = apply func args
applyProc (func : args) = apply func args

makePort :: IOMode -> [LispVal] -> EvalM LispVal
makePort mode [String filename] = fmap Port $ liftIO $ openFile filename mode

closePort :: [LispVal] -> EvalM LispVal
closePort [Port port] = liftIO $ hClose port >> (return $ Bool True)
closePort _ = return $ Bool False

readProc :: [LispVal] -> EvalM LispVal
readProc [] = readProc [Port stdin]
readProc [Port port] = (liftIO $ hGetLine stdin) >>= liftThrows . readExpr

writeProc :: [LispVal] -> EvalM LispVal
writeProc [obj] = writeProc [obj, Port stdout]
writeProc [obj, Port port] = liftIO $ hPrint port obj >> (return $ Bool True)

readContents :: [LispVal] -> EvalM LispVal
readContents [String filename] = fmap String $ liftIO $ readFile filename

load :: String -> EvalM [LispVal]
load filename = (liftIO $ readFile filename) >>= liftThrows . readExprList

readAll :: [LispVal] -> EvalM LispVal
readAll [String filename] = fmap List $ load filename
