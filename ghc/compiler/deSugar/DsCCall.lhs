%
% (c) The AQUA Project, Glasgow University, 1994-1998
%
\section[DsCCall]{Desugaring \tr{_ccall_}s and \tr{_casm_}s}

\begin{code}
module DsCCall 
	( dsCCall
	, mkFCall
	, unboxArg
	, boxResult
	, resultWrapper
	) where

#include "HsVersions.h"

import CoreSyn

import DsMonad

import CoreUtils	( exprType )
import Id		( Id, mkWildId, idType )
import MkId		( mkFCallId, realWorldPrimId, mkPrimOpId )
import Maybes		( maybeToBool )
import ForeignCall	( ForeignCall(..), CCallSpec(..), CCallTarget(..), Safety, CCallConv(..) )
import DataCon		( splitProductType_maybe, dataConSourceArity, dataConWrapId )
import ForeignCall	( ForeignCall, CCallTarget(..) )

import TcType		( Type, isUnLiftedType, mkFunTys, mkFunTy,
			  tyVarsOfType, mkForAllTys, mkTyConApp, 
			  isBoolTy, isUnitTy, isPrimitiveType,
			  tcSplitTyConApp_maybe
			)
import Type		( repType, eqType )	-- Sees the representation type
import PrimOp		( PrimOp(TouchOp) )
import TysPrim		( realWorldStatePrimTy,
			  byteArrayPrimTyCon, mutableByteArrayPrimTyCon,
			  intPrimTy, foreignObjPrimTy
			)
import TyCon		( tyConDataCons )
import TysWiredIn	( unitDataConId,
			  unboxedSingletonDataCon, unboxedPairDataCon,
			  unboxedSingletonTyCon, unboxedPairTyCon,
			  trueDataCon, falseDataCon, 
			  trueDataConId, falseDataConId 
			)
import Literal		( mkMachInt )
import CStrings		( CLabelString )
import PrelNames	( Unique, hasKey, ioTyConKey )
import VarSet		( varSetElems )
import Outputable
\end{code}

Desugaring of @ccall@s consists of adding some state manipulation,
unboxing any boxed primitive arguments and boxing the result if
desired.

The state stuff just consists of adding in
@PrimIO (\ s -> case s of { S# s# -> ... })@ in an appropriate place.

The unboxing is straightforward, as all information needed to unbox is
available from the type.  For each boxed-primitive argument, we
transform:
\begin{verbatim}
   _ccall_ foo [ r, t1, ... tm ] e1 ... em
   |
   |
   V
   case e1 of { T1# x1# ->
   ...
   case em of { Tm# xm# -> xm#
   ccall# foo [ r, t1#, ... tm# ] x1# ... xm#
   } ... }
\end{verbatim}

The reboxing of a @_ccall_@ result is a bit tricker: the types don't
contain information about the state-pairing functions so we have to
keep a list of \tr{(type, s-p-function)} pairs.  We transform as
follows:
\begin{verbatim}
   ccall# foo [ r, t1#, ... tm# ] e1# ... em#
   |
   |
   V
   \ s# -> case (ccall# foo [ r, t1#, ... tm# ] s# e1# ... em#) of
	  (StateAnd<r># result# state#) -> (R# result#, realWorld#)
\end{verbatim}

\begin{code}
dsCCall :: CLabelString	-- C routine to invoke
	-> [CoreExpr]	-- Arguments (desugared)
	-> Safety	-- Safety of the call
	-> Bool		-- True <=> really a "_casm_"
	-> Type		-- Type of the result: IO t
	-> DsM CoreExpr

dsCCall lbl args may_gc is_asm result_ty
  = mapAndUnzipDs unboxArg args	`thenDs` \ (unboxed_args, arg_wrappers) ->
    boxResult [] ({-repType-} result_ty)	`thenDs` \ (ccall_result_ty, res_wrapper) ->
    getUniqueDs			`thenDs` \ uniq ->
    let
	target | is_asm    = CasmTarget lbl
	       | otherwise = StaticTarget lbl
	the_fcall    = CCall (CCallSpec target CCallConv may_gc)
 	the_prim_app = mkFCall uniq the_fcall unboxed_args ccall_result_ty
    in
    returnDs (foldr ($) (res_wrapper the_prim_app) arg_wrappers)

mkFCall :: Unique -> ForeignCall 
	-> [CoreExpr] 	-- Args
	-> Type 	-- Result type
	-> CoreExpr
-- Construct the ccall.  The only tricky bit is that the ccall Id should have
-- no free vars, so if any of the arg tys do we must give it a polymorphic type.
-- 	[I forget *why* it should have no free vars!]
-- For example:
--	mkCCall ... [s::StablePtr (a->b), x::Addr, c::Char]
--
-- Here we build a ccall thus
--	(ccallid::(forall a b.  StablePtr (a -> b) -> Addr -> Char -> IO Addr))
--			a b s x c
mkFCall uniq the_fcall val_args res_ty
  = mkApps (mkVarApps (Var the_fcall_id) tyvars) val_args
  where
    arg_tys = map exprType val_args
    body_ty = (mkFunTys arg_tys res_ty)
    tyvars  = varSetElems (tyVarsOfType body_ty)
    ty 	    = mkForAllTys tyvars body_ty
    the_fcall_id = mkFCallId uniq the_fcall ty
\end{code}

\begin{code}
unboxArg :: CoreExpr			-- The supplied argument
	 -> DsM (CoreExpr,		-- To pass as the actual argument
		 CoreExpr -> CoreExpr	-- Wrapper to unbox the arg
		)
-- Example: if the arg is e::Int, unboxArg will return
--	(x#::Int#, \W. case x of I# x# -> W)
-- where W is a CoreExpr that probably mentions x#

unboxArg arg
  -- Primtive types: nothing to unbox
  | isPrimitiveType arg_ty
  = returnDs (arg, \body -> body)

  -- Booleans
  | isBoolTy arg_ty
  = newSysLocalDs intPrimTy		`thenDs` \ prim_arg ->
    returnDs (Var prim_arg,
	      \ body -> Case (Case arg (mkWildId arg_ty)
  		                       [(DataAlt falseDataCon,[],mkIntLit 0),
	                                (DataAlt trueDataCon, [],mkIntLit 1)])
                             prim_arg 
			     [(DEFAULT,[],body)])

  -- Data types with a single constructor, which has a single, primitive-typed arg
  -- This deals with Int, Float etc
  | is_product_type && data_con_arity == 1 
  = ASSERT(isUnLiftedType data_con_arg_ty1 )	-- Typechecker ensures this
    newSysLocalDs arg_ty		`thenDs` \ case_bndr ->
    newSysLocalDs data_con_arg_ty1	`thenDs` \ prim_arg ->
    returnDs (Var prim_arg,
	      \ body -> Case arg case_bndr [(DataAlt data_con,[prim_arg],body)]
    )

  -- Byte-arrays, both mutable and otherwise; hack warning
  -- We're looking for values of type ByteArray, MutableByteArray
  --	data ByteArray          ix = ByteArray        ix ix ByteArray#
  --	data MutableByteArray s ix = MutableByteArray ix ix (MutableByteArray# s)
  | is_product_type &&
    data_con_arity == 3 &&
    maybeToBool maybe_arg3_tycon &&
    (arg3_tycon ==  byteArrayPrimTyCon ||
     arg3_tycon ==  mutableByteArrayPrimTyCon)
    -- and, of course, it is an instance of CCallable
  = newSysLocalDs arg_ty		`thenDs` \ case_bndr ->
    newSysLocalsDs data_con_arg_tys	`thenDs` \ vars@[l_var, r_var, arr_cts_var] ->
    returnDs (Var arr_cts_var,
	      \ body -> Case arg case_bndr [(DataAlt data_con,vars,body)]
    )

  | otherwise
  = getSrcLocDs `thenDs` \ l ->
    pprPanic "unboxArg: " (ppr l <+> ppr arg_ty)
  where
    arg_ty  					= repType (exprType arg)
	-- The repType looks through any newtype or 
	-- implicit-parameter wrappings on the argument;
	-- this is necessary, because isBoolTy (in particular) does not.

    maybe_product_type 			   	= splitProductType_maybe arg_ty
    is_product_type			   	= maybeToBool maybe_product_type
    Just (_, _, data_con, data_con_arg_tys)	= maybe_product_type
    data_con_arity				= dataConSourceArity data_con
    (data_con_arg_ty1 : _)			= data_con_arg_tys

    (_ : _ : data_con_arg_ty3 : _) = data_con_arg_tys
    maybe_arg3_tycon    	   = tcSplitTyConApp_maybe data_con_arg_ty3
    Just (arg3_tycon,_)		   = maybe_arg3_tycon
\end{code}


\begin{code}
boxResult :: [Id] -> Type -> DsM (Type, CoreExpr -> CoreExpr)

-- Takes the result of the user-level ccall: 
--	either (IO t), 
--	or maybe just t for an side-effect-free call
-- Returns a wrapper for the primitive ccall itself, along with the
-- type of the result of the primitive ccall.  This result type
-- will be of the form  
--	State# RealWorld -> (# State# RealWorld, t' #)
-- where t' is the unwrapped form of t.  If t is simply (), then
-- the result type will be 
--	State# RealWorld -> (# State# RealWorld #)

-- Here is where we arrange that ForeignPtrs which are passed to a 'safe'
-- foreign import don't get finalized until the call returns.  For each
-- argument of type ForeignObj# we arrange to touch# the argument after
-- the call.  The arg_ids passed in are the Ids passed to the actual ccall.

boxResult arg_ids result_ty
  = case tcSplitTyConApp_maybe result_ty of
	-- This split absolutely has to be a tcSplit, because we must
	-- see the IO type; and it's a newtype which is transparent to splitTyConApp.

	-- The result is IO t, so wrap the result in an IO constructor
	Just (io_tycon, [io_res_ty]) | io_tycon `hasKey` ioTyConKey
		-> mk_alt return_result 
			  (resultWrapper io_res_ty)	`thenDs` \ (ccall_res_ty, the_alt) ->
		   newSysLocalDs  realWorldStatePrimTy	 `thenDs` \ state_id ->
		   let
			io_data_con = head (tyConDataCons io_tycon)
			wrap = \ the_call -> 
				 mkApps (Var (dataConWrapId io_data_con))
					   [ Type io_res_ty, 
					     Lam state_id $
					      Case (App the_call (Var state_id))
						   (mkWildId ccall_res_ty)
						   [the_alt]
					   ]
		   in
		   returnDs (realWorldStatePrimTy `mkFunTy` ccall_res_ty, wrap)
		where
		   return_result state ans = mkConApp unboxedPairDataCon 
						      [Type realWorldStatePrimTy, Type io_res_ty, 
						       state, ans]

	-- It isn't, so do unsafePerformIO
	-- It's not conveniently available, so we inline it
	other -> mk_alt return_result
			(resultWrapper result_ty) `thenDs` \ (ccall_res_ty, the_alt) ->
		 let
		    wrap = \ the_call -> Case (App the_call (Var realWorldPrimId)) 
					      (mkWildId ccall_res_ty)
					      [the_alt]
		 in
		 returnDs (realWorldStatePrimTy `mkFunTy` ccall_res_ty, wrap)
	      where
		 return_result state ans = ans
  where
    mk_alt return_result (Nothing, wrap_result)
	= 	-- The ccall returns ()
	  let
		rhs_fun state_id = return_result (Var state_id) 
					(wrap_result (panic "boxResult"))
	  in
	  newSysLocalDs realWorldStatePrimTy	`thenDs` \ state_id ->
	  mkTouches arg_ids state_id rhs_fun	`thenDs` \ the_rhs ->
	  let
		ccall_res_ty = mkTyConApp unboxedSingletonTyCon [realWorldStatePrimTy]
		the_alt      = (DataAlt unboxedSingletonDataCon, [state_id], the_rhs)
	  in
	  returnDs (ccall_res_ty, the_alt)

    mk_alt return_result (Just prim_res_ty, wrap_result)
	=	-- The ccall returns a non-() value
	  newSysLocalDs prim_res_ty 		`thenDs` \ result_id ->
	  let
		rhs_fun state_id = return_result (Var state_id) 
					(wrap_result (Var result_id))
	  in
	  newSysLocalDs realWorldStatePrimTy	`thenDs` \ state_id ->
	  mkTouches arg_ids state_id rhs_fun	`thenDs` \ the_rhs ->
	  let
		ccall_res_ty = mkTyConApp unboxedPairTyCon [realWorldStatePrimTy, prim_res_ty]
		the_alt	     = (DataAlt unboxedPairDataCon, [state_id, result_id], the_rhs)
	  in
	  returnDs (ccall_res_ty, the_alt)

touchzh = mkPrimOpId TouchOp

mkTouches []     s cont = returnDs (cont s)
mkTouches (v:vs) s cont
  | not (idType v `eqType` foreignObjPrimTy) = mkTouches vs s cont
  | otherwise = newSysLocalDs realWorldStatePrimTy `thenDs` \s' -> 
		mkTouches vs s' cont `thenDs` \ rest ->
	        returnDs (Case (mkApps (Var touchzh) [Type foreignObjPrimTy, 
						      Var v, Var s]) s' 
				[(DEFAULT, [], rest)])

resultWrapper :: Type
   	      -> (Maybe Type,		-- Type of the expected result, if any
		  CoreExpr -> CoreExpr)	-- Wrapper for the result 
resultWrapper result_ty
  -- Base case 1: primitive types
  | isPrimitiveType result_ty_rep
  = (Just result_ty, \e -> e)

  -- Base case 2: the unit type ()
  | isUnitTy result_ty_rep
  = (Nothing, \e -> Var unitDataConId)

  -- Base case 3: the boolean type ()
  | isBoolTy result_ty_rep
  = (Just intPrimTy, \e -> Case e (mkWildId intPrimTy)
	                          [(DEFAULT             ,[],Var trueDataConId ),
				   (LitAlt (mkMachInt 0),[],Var falseDataConId)])

  -- Data types with a single constructor, which has a single arg
  | Just (_, tycon_arg_tys, data_con, data_con_arg_tys) <- splitProductType_maybe result_ty_rep,
    dataConSourceArity data_con == 1
  = let
        (maybe_ty, wrapper)    = resultWrapper unwrapped_res_ty
	(unwrapped_res_ty : _) = data_con_arg_tys
    in
    (maybe_ty, \e -> mkApps (Var (dataConWrapId data_con)) 
			    (map Type tycon_arg_tys ++ [wrapper e]))

  | otherwise
  = pprPanic "resultWrapper" (ppr result_ty)
  where
    result_ty_rep = repType result_ty	-- Look through any newtypes/implicit parameters
\end{code}
