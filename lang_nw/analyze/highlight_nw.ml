(* Yoann Padioleau
 *
 * Copyright (C) 2010 Facebook
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

open Ast_nw

module Ast = Ast_nw
(*module V = Visitor_nw *)

open Highlight_code

module T = Parser_nw
module TH = Token_helpers_nw

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let span_close_brace xs = 
  Common.split_when (function 
  | T.TCBrace _ -> true
  | _ -> false
  ) xs

let tag_all_tok_with ~tag categ xs = 
  xs +> List.iter (fun tok ->
    let info = TH.info_of_tok tok in
    tag info categ
  )

(*****************************************************************************)
(* Code highlighter *)
(*****************************************************************************)

(* The idea of the code below is to visit the program either through its
 * AST or its list of tokens. The tokens are easier for tagging keywords,
 * number and basic entities. The Ast is better for tagging idents
 * to figure out what kind of ident it is.
 *)

let visit_toplevel 
    ~tag_hook
    prefs 
    (*db_opt *)
    (toplevel, toks)
  =
  let already_tagged = Hashtbl.create 101 in
  let tag = (fun ii categ ->
    tag_hook ii categ;
    Hashtbl.replace already_tagged ii true
  )
  in


  (* -------------------------------------------------------------------- *)
  (* toks phase 1 *)
  (* -------------------------------------------------------------------- *)

  let rec aux_toks xs = 
    match xs with
    | [] -> ()
    (* a little bit pad specific *)
    |   T.TComment(ii)
      ::T.TCommentNewline (ii2)
      ::T.TComment(ii3)
      ::T.TCommentNewline (ii4)
      ::T.TComment(ii5)
      ::xs ->
        let s = Parse_info.str_of_info ii in
        let s5 =  Parse_info.str_of_info ii5 in
        (match () with
        | _ when s =~ ".*\\*\\*\\*\\*" && s5 =~ ".*\\*\\*\\*\\*" ->
          tag ii CommentEstet;
          tag ii5 CommentEstet;
          tag ii3 CommentSection0
        | _ when s =~ ".*------" && s5 =~ ".*------" ->
          tag ii CommentEstet;
          tag ii5 CommentEstet;
          tag ii3 CommentSection1
        | _ when s =~ ".*####" && s5 =~ ".*####" ->
          tag ii CommentEstet;
          tag ii5 CommentEstet;
          tag ii3 CommentSection2
        | _ ->
            ()
        );
        aux_toks xs

    |    T.TCommand(("chapter" | "chapter*") ,_)
      :: T.TOBrace _
      :: xs 
      ->
       let (before, _, _) = span_close_brace xs in
       tag_all_tok_with ~tag CommentSection0 before;
       (* repass on tokens, in case there are nested tex commands *)
       aux_toks xs

    |    T.TCommand("section",_)
      :: T.TOBrace _
      :: xs 
      ->
       let (before, _, _) = span_close_brace xs in
       tag_all_tok_with ~tag CommentSection1 before;
       (* repass on tokens, in case there are nested tex commands *)
       aux_toks xs

    |    T.TCommand("subsection",_)
      :: T.TOBrace _
      :: xs 
      ->
       let (before, _, _) = span_close_brace xs in
       tag_all_tok_with ~tag CommentSection2 before;
       (* repass on tokens, in case there are nested tex commands *)
       aux_toks xs


    | x::xs ->
        aux_toks xs
  in
  let toks' = toks +> Common.exclude (function
    (* needed ? *)
    (* | T.TCommentSpace _ -> true *)
    | _ -> false
  )
  in
  aux_toks toks';

  (* -------------------------------------------------------------------- *)
  (* ast phase 1 *) 

  (* -------------------------------------------------------------------- *)
  (* toks phase 2 *)

  toks +> List.iter (fun tok -> 
    match tok with
    | T.TComment ii ->
        if not (Hashtbl.mem already_tagged ii)
        then
          tag ii Comment

    | T.TCommentNewline ii | T.TCommentSpace ii 
      -> ()

    | T.TCommand (s, ii) ->
        tag ii Keyword
        
    | T.TWord (_, ii) ->
        if not (Hashtbl.mem already_tagged ii)
        then
          ()



    | T.TBeginNowebChunk ii
    | T.TEndNowebChunk ii
      ->
        tag ii KeywordExn (* TODO *)

    | T.TNowebChunkLine (_, ii) ->
        tag ii BuiltinBoolean (* TODO *)


    | T.TBeginVerbatim ii
    | T.TEndVerbatim ii
        -> 
        tag ii KeywordLoop

    | T.TVerbatimLine (_, ii) ->
        tag ii KeywordModule (* TODO *)

    | T.TNumber (_, ii) -> tag ii Number
    | T.TSymbol (_, ii) -> tag ii Punctuation


    | T.TOBrace ii | T.TCBrace ii
      ->
        tag ii Punctuation

    | T.TUnknown ii 
      -> tag ii Error
    | T.EOF ii
      -> ()

  );

  (* -------------------------------------------------------------------- *)
  (* ast phase 2 *)  

  ()