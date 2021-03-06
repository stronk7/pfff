(* Julien Verlaguet, Yoann Padioleau
 *
 * Copyright (C) 2011, 2012 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common

module Ast = Ast_php_simple

module ISet = Set.Make (Int)
module IMap = Map.Make (Int)
module SSet = Set.Make (String)
module SMap = Map.Make (String)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
 * In the abstract interpreter all variables are pointers to pointers 
 * of values. So with '$x = 42;' we got $x = &1{&2{42}}.
 * In 'env.vars' we got "$x" -> Vptr 1
 * and in the 'heap' we then got [1 -> Vptr 2; 2 -> Vint 42]
 * meaning that $x is a variable with address 1, where the content
 * of this cell is a pointer to address 2, where the content of
 * this cell is the value 42.
 *
 * Why this model? why not just variables be pointer to values? Because
 * of references.
 * 
 * Retrospecively, was it good to try to manage references correctly?
 * After all, many other things are not that well handled in the interpreter
 * or imprecise or passed over silently (e.g. many functions/classes not
 * found, traits not handled, some constructs not handled, choosing
 * arbitrarily one object in a Vsum when there could actually be many
 * different classes).
 * juju: yes, maybe it was not a good idea to focus so much on references.
 *       Moreover it slows down things a lot.
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type code_database = {
  funs:      string -> Ast.func_def;
  classes:   string -> Ast.class_def;
  constants: string -> Ast.constant_def;
}

type value =
  | Vany
  (* can be useful for nullpointer analysis *)
  | Vnull

  | Vabstr  of type_

  (* Precise value. Especially useful for Vstring for interprocedural
   * analysis as people use strings to represent functions or classnames
   * (they are not first-class citizens in PHP).
   *)
  | Vbool   of bool
  | Vint    of int
  | Vfloat  of float
  | Vstring of string

  (* a pointer is an int address in the heap *)
  | Vptr    of int
  (* pad: because of some imprecision, we actually have a set of addresses ? *)
  | Vref    of ISet.t

  (* try to differentiate the different (abusive) usage of PHP arrays *)
  | Vrecord of value SMap.t
  | Varray  of value list
  | Vmap of value * value

  (* pad: ??? *)
  | Vmethod of value * (env -> heap -> Ast.expr list -> heap * value) IMap.t
  | Vobject of value SMap.t

  (* union of possible types/values, ex: null | object, bool | string, etc *)
  | Vsum    of value list

  (* tainting analysis for security *)
  | Vtaint of string

  and type_ =
    | Tint
    | Tbool
    | Tfloat
    | Tstring
    (* useful for tainting analysis again *)
    | Txhp

and heap = {
  (* a heap maps addresses to values *)
  ptrs: value IMap.t;
}

(* mutually recursive types because Vmethod above needs an env *)
and env = {
  db: code_database;

  (* local variables and parameters *)
  vars    : value SMap.t ref;
  (* globals and static variables (prefixed with a "<function>**" *)
  globals : value SMap.t ref;

  (* for debugging, to print for instance in which file we have XSS  *)
  file    : string ref;
  (* current function processed, used for handling static variables,
   * to add fake "<function>**$var" in globals *)
  cfun    : string;
  (* call stack used for debugging when found an XSS hole and used also
   * for callgraph generation.
   * todo: could be put in the env too, next to 'stack' and 'safe'? take
   * care of save_excursion though.
   *)
  path: Callgraph_php2.node list ref;
  (* opti: number of recursive calls to a function f. if > 2 then stop. *)
  stack   : int SMap.t;

  (* opti: cache of already processed functions safe for tainting *)
  safe    : value SMap.t ref;
}

module type TAINT =
  sig
    val taint_mode : bool ref

    val taint_expr : env -> heap ->
      (env -> heap -> Ast_php_simple.expr -> heap * value) *
      (env -> heap -> Ast_php_simple.expr -> heap * bool * value) *
      (env -> heap -> value -> 'a * 'b) *
      ('b -> env -> 'a -> Ast_php_simple.expr list -> heap * value) *
      (env -> heap -> value -> Ast_php_simple.expr list -> heap * value) ->
      Callgraph_php2.node list ->
      Ast_php_simple.expr -> 
      heap * value

    val binary_concat : env -> heap ->
      value -> value -> 
      Callgraph_php2.node list (* path *) -> 
      value

    val check_danger :  env -> heap ->
      string -> Ast_php.info option -> Callgraph_php2.node list (* path *) -> 
      value -> unit

    val fold_slist : value list -> value

    val when_call_not_found : heap -> value list -> value

    module GetTaint :
      sig
        exception Found of string list
        val list : ('a -> unit) -> 'a list -> unit
        val value : heap -> value -> string list option
      end
  end


(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let empty_heap = {
  ptrs  = IMap.empty;
}

let empty_env db file =
  let globals = ref SMap.empty in
  { file = ref file;
    globals = globals;
    (* why use same ref? because when we process toplevel statements,
     * the vars are the globals.
     *)
    vars = globals; 
    cfun = "*TOPLEVEL*";
    stack   = SMap.empty ;
    safe = ref SMap.empty;
    db = db;
    path = ref [];
  }

(*****************************************************************************)
(* String-of like *)
(*****************************************************************************)

let rec list o f l =
  match l with
  | [] -> ()
  | [x] -> f o x
  | x :: rl -> f o x; o ", "; list o f rl

let rec value ptrs o x =
  match x with
  | Vany -> o "Any"
  | Vnull -> o "Null"
  | Vtaint s -> o "PARAM:"; o s
  | Vabstr ty -> type_ o ty
  | Vbool b -> o (string_of_bool b)
  | Vint n -> o (string_of_int n)
  | Vref s ->
      o "&REF ";
      let l = ISet.elements s in
      list o (fun o x -> o (string_of_int x)) l;
      let n = ISet.choose s in
      (try
          o "{";
          value (IMap.remove n ptrs) o (IMap.find n ptrs);
          o "}"
      with Not_found -> o "rec"
      )
  | Vptr n when IMap.mem n ptrs ->
      o "&";
      o (string_of_int n);
      o "{";
      value (IMap.remove n ptrs) o (IMap.find n ptrs);
      o "}"
  | Vptr _ -> o "rec"
  | Vfloat f -> o (string_of_float f)
  | Vstring s ->
      o "'";
      o s;
      o "'"
  | Vrecord m ->
      let vl = SMap.fold (fun x y acc -> (x, y) :: acc) m [] in
      o "record(";
      list o (fun o (x, v) -> o "'"; o x ; o "' => "; value ptrs o v) vl;
      o ")"
  | Vobject m ->
      let vl = SMap.fold (fun x y acc -> (x, y) :: acc) m [] in
      o "object(";
      list o (fun o (x, v) -> o "'"; o x ; o "' => "; value ptrs o v) vl;
      o ")"
  | Varray vl ->
      o "array(";
      list o (value ptrs) (List.rev vl);
      o ")";
  | Vmap (v1, v2) ->
      o "[";
      value ptrs o v1;
      o " => ";
      value ptrs o v2;
      o "]"
  | Vmethod _ -> o "method"
  | Vsum vl ->
      o "choice(";
      list o (value ptrs) vl;
      o ")"

and type_ o x =
  match x with
  | Tint -> o "int"
  | Tbool -> o "bool"
  | Tfloat -> o "float"
  | Tstring -> o "string"
  | Txhp -> o "xhp"

(*****************************************************************************)
(* Printing *)
(*****************************************************************************)

and penv o env heap =
  SMap.iter (fun s v ->
      o s ; o " = "; value heap.ptrs o v; o "\n"
  ) !(env.vars);
  SMap.iter (fun s v ->
      o "GLOBAL "; o s ; o " = "; value heap.ptrs o v; o "\n"
  ) !(env.globals)

let debug heap x =
  value heap.ptrs print_string x;
  print_newline()

let sdebug s heap x =
  print_string (s^": ");
  debug heap x

(*****************************************************************************)
(* Debugging *)
(*****************************************************************************)

let string_of_value heap v =
  Common.with_open_stringbuf (fun (_pr, buf) ->
    let pr s = Buffer.add_string buf s in
    value heap.ptrs pr v
  )

let string_of_chained_values heap xs =
  "[" ^ (Common.join ", " (List.map (fun x -> string_of_value heap x) xs)) ^ "]"
