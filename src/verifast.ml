open Proverapi

class stats =
  object (self)
    val mutable stmtsParsedCount = 0
    val mutable stmtExecCount = 0
    val mutable execStepCount = 0
    val mutable branchCount = 0
    val mutable proverCmdCount = 0
    val mutable proverQueryCount = 0
    
    method stmtParsed = stmtsParsedCount <- stmtsParsedCount + 1
    method stmtExec = stmtExecCount <- stmtExecCount + 1
    method execStep = execStepCount <- execStepCount + 1
    method branch = branchCount <- branchCount + 1
    method proverCmd = proverCmdCount <- proverCmdCount + 1
    method proverQuery = proverQueryCount <- proverQueryCount + 1
    
    method printStats =
      print_endline ("Statements parsed: " ^ string_of_int stmtsParsedCount);
      print_endline ("Statement executions: " ^ string_of_int stmtExecCount);
      print_endline ("Execution steps (including assertion production/consumption steps): " ^ string_of_int execStepCount);
      print_endline ("Branches: " ^ string_of_int branchCount);
      print_endline ("Prover commands: " ^ string_of_int proverCmdCount);
      print_endline ("Prover queries: " ^ string_of_int proverQueryCount)
  end

let stats = new stats

let readFile path =
  let chan = open_in path in
  let count = ref 0 in
  let rec iter () =
    let buf = String.create 60000 in
    let result = input chan buf 0 60000 in
    count := !count + result;
    if result = 0 then [] else (buf, result)::iter()
  in
  let chunks = iter() in
  let _ = close_in chan in
  let s = String.create !count in
  let rec iter2 chunks offset =
    match chunks with
      [] -> ()
    | (buf, size)::chunks ->
      String.blit buf 0 s offset size;
      iter2 chunks (offset + size)
  in
  iter2 chunks 0;
  s

type token =
    Kwd of string
  | Ident of string
  | Int of int
  | Float of float
  | String of string
  | Char of char
  | Eol

type srcpos = (string * int * int)
type loc = (srcpos * srcpos)

exception ParseException of loc * string

(* The lexer *)

let make_lexer keywords path stream reportKeyword =
  let initial_buffer = String.create 32
  in

  let buffer = ref initial_buffer
  in
  let bufpos = ref 0
  in

  let reset_buffer () = buffer := initial_buffer; bufpos := 0
  in

  let store c =
    if !bufpos >= String.length !buffer then
      begin
        let newbuffer = String.create (2 * !bufpos) in
        String.blit !buffer 0 newbuffer 0 !bufpos; buffer := newbuffer
      end;
    String.set !buffer !bufpos c;
    incr bufpos
  in

  let get_string () =
    let s = String.sub !buffer 0 !bufpos in buffer := initial_buffer; s
  in

  let line = ref 1 in
  let linepos = ref 0 in  (* Stream count at start of line *)
  let tokenpos = ref 0 in
  let token_srcpos = ref (path, -1, -1) in

  let current_srcpos() = (path, !line, Stream.count stream - !linepos + 1) in
  let current_loc() = (!token_srcpos, current_srcpos()) in

  let in_single_line_annotation = ref false in
  
  let kwd_table = Hashtbl.create 17 in
  List.iter (fun s -> Hashtbl.add kwd_table s (Kwd s)) keywords;
  let ident_or_keyword id isAlpha =
    try let t = Hashtbl.find kwd_table id in if isAlpha then reportKeyword (current_loc()); t with
      Not_found -> Ident id
  and keyword_or_error c =
    let s = String.make 1 c in
    try Hashtbl.find kwd_table s with
      Not_found -> raise (Stream.Error ("Illegal character"))
  in
  let start_token() =
    tokenpos := Stream.count stream;
    token_srcpos := current_srcpos()
  in
  let new_loc_line strm__ =
      line := !line + 1;
      linepos := Stream.count strm__
  in
  let rec next_token (strm__ : _ Stream.t) =
    let new_line strm__ =
      new_loc_line strm__;
      if !in_single_line_annotation then (
        in_single_line_annotation := false;
        Some (Kwd "@*/")
      ) else
        Some Eol
    in
    match Stream.peek strm__ with
      Some (' ' | '\009' | '\026' | '\012') ->
        Stream.junk strm__; next_token strm__
    | Some '\010' ->
        Stream.junk strm__; new_line strm__
    | Some '\013' ->
        Stream.junk strm__;
        if Stream.peek strm__ = Some '\010' then Stream.junk strm__;
        new_line strm__
    | Some ('A'..'Z' | 'a'..'z' | '_' | '\192'..'\255' as c) ->
        start_token();
        Stream.junk strm__;
        let s = strm__ in reset_buffer (); store c; ident s
    | Some '(' -> Stream.junk strm__; Some(ident_or_keyword "(" false)
    | Some
        ('!' | '%' | '&' | '$' | '#' | '+' | ':' | '<' | '=' | '>' |
         '?' | '@' | '\\' | '~' | '^' | '|' | '*' as c) ->
        start_token();
        Stream.junk strm__;
        let s = strm__ in reset_buffer (); store c; ident2 s
    | Some ('0'..'9' as c) ->
        start_token();
        Stream.junk strm__;
        let s = strm__ in reset_buffer (); store c; number s
    | Some '\'' ->
        start_token();
        Stream.junk strm__;
        let c =
          try char strm__ with
            Stream.Failure -> raise (Stream.Error "Bad character literal.")
        in
        begin match Stream.peek strm__ with
          Some '\'' -> Stream.junk strm__; Some (Char c)
        | _ -> raise (Stream.Error "Single quote expected.")
        end
    | Some '"' ->
        start_token();
        Stream.junk strm__;
        let s = strm__ in reset_buffer (); Some (String (string s))
    | Some '-' -> start_token(); Stream.junk strm__; neg_number strm__
    | Some '/' -> start_token(); Stream.junk strm__; maybe_comment strm__
    | Some c -> start_token(); Stream.junk strm__; Some (keyword_or_error c)
    | _ -> None
  and ident (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some
        ('A'..'Z' | 'a'..'z' | '\192'..'\255' | '0'..'9' | '_' | '\'' as c) ->
        Stream.junk strm__; let s = strm__ in store c; ident s
    | _ -> Some (ident_or_keyword (get_string ()) true)
  and ident2 (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some
        ('!' | '%' | '&' | '$' | '#' | '+' | '-' | '/' | ':' | '<' | '=' |
         '>' | '?' | '@' | '\\' | '~' | '^' | '|' | '*' as c) ->
        Stream.junk strm__; let s = strm__ in store c; ident2 s
    | _ -> Some (ident_or_keyword (get_string ()) false)
  and neg_number (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some ('0'..'9' as c) ->
        Stream.junk strm__;
        let s = strm__ in reset_buffer (); store '-'; store c; number s
    | _ -> let s = strm__ in reset_buffer (); store '-'; ident2 s
  and number (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some ('0'..'9' as c) ->
        Stream.junk strm__; let s = strm__ in store c; number s
    | Some '.' ->
        Stream.junk strm__; let s = strm__ in store '.'; decimal_part s
    | Some ('e' | 'E') ->
        Stream.junk strm__; let s = strm__ in store 'E'; exponent_part s
    | _ -> Some (Int (int_of_string (get_string ())))
  and decimal_part (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some ('0'..'9' as c) ->
        Stream.junk strm__; let s = strm__ in store c; decimal_part s
    | Some ('e' | 'E') ->
        Stream.junk strm__; let s = strm__ in store 'E'; exponent_part s
    | _ -> Some (Float (float_of_string (get_string ())))
  and exponent_part (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some ('+' | '-' as c) ->
        Stream.junk strm__; let s = strm__ in store c; end_exponent_part s
    | _ -> end_exponent_part strm__
  and end_exponent_part (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some ('0'..'9' as c) ->
        Stream.junk strm__; let s = strm__ in store c; end_exponent_part s
    | _ -> Some (Float (float_of_string (get_string ())))
  and string (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some '"' -> Stream.junk strm__; get_string ()
    | Some '\\' ->
        Stream.junk strm__;
        let c =
          try escape strm__ with
            Stream.Failure -> raise (Stream.Error "Bad string literal.")
        in
        let s = strm__ in store c; string s
    | Some c -> Stream.junk strm__; let s = strm__ in store c; string s
    | _ -> raise Stream.Failure
  and char (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some '\\' ->
        Stream.junk strm__;
        begin try escape strm__ with
          Stream.Failure -> raise (Stream.Error "Bad character literal.")
        end
    | Some c -> Stream.junk strm__; c
    | _ -> raise Stream.Failure
  and escape (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some 'n' -> Stream.junk strm__; '\n'
    | Some 'r' -> Stream.junk strm__; '\r'
    | Some 't' -> Stream.junk strm__; '\t'
    | Some ('0'..'9' as c1) ->
        Stream.junk strm__;
        begin match Stream.peek strm__ with
          Some ('0'..'9' as c2) ->
            Stream.junk strm__;
            begin match Stream.peek strm__ with
              Some ('0'..'9' as c3) ->
                Stream.junk strm__;
                Char.chr
                  ((Char.code c1 - 48) * 100 + (Char.code c2 - 48) * 10 +
                     (Char.code c3 - 48))
            | _ -> raise (Stream.Error "Bad escape sequence.")
            end
        | _ -> raise (Stream.Error "Bad escape sequence.")
        end
    | Some c -> Stream.junk strm__; c
    | _ -> raise Stream.Failure
  and maybe_comment (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some '/' ->
      Stream.junk strm__;
      (
        match Stream.peek strm__ with
          Some '@' -> (Stream.junk strm__; in_single_line_annotation := true; Some (Kwd "/*@"))
        | _ ->
          if !in_single_line_annotation then (
            in_single_line_annotation := false; single_line_comment strm__; Some (Kwd "@*/")
          ) else (
            single_line_comment strm__; next_token strm__
          )
      )
    | Some '*' ->
      Stream.junk strm__;
      (
        match Stream.peek strm__ with
          Some '@' -> (Stream.junk strm__; Some (Kwd "/*@"))
        | _ -> (multiline_comment strm__; next_token strm__)
      )
    | _ -> Some (keyword_or_error '/')
  and single_line_comment (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some '\010' | Some '\013' -> ()
    | Some c -> Stream.junk strm__; single_line_comment strm__
    | _ -> raise Stream.Failure
  and multiline_comment (strm__ : _ Stream.t) =
    match Stream.peek strm__ with
      Some '*' ->
      (
        Stream.junk strm__;
        (
          match Stream.peek strm__ with
            Some '/' -> (Stream.junk strm__; ())
          | _ -> multiline_comment strm__
        )
      )
    | Some '\010' -> (Stream.junk strm__; new_loc_line strm__; multiline_comment strm__)
    | Some '\013' ->
      (Stream.junk strm__;
       (match Stream.peek strm__ with
        | Some '\010' -> Stream.junk strm__
        | _ -> ());
       new_loc_line strm__;
       multiline_comment strm__
      )
    | _ -> (Stream.junk strm__; multiline_comment strm__)
  in
  (current_loc,
   Stream.from (fun count ->
     (match next_token stream with
        Some t -> Some (current_loc(), t)
      | None -> None)))

let preprocess path loc stream streamSource =
  let path = ref path in
  let loc = ref loc in
  let stream = ref stream in
  let startOfLine = ref true in
  let stack: (string * (unit -> loc) * (loc * token) Stream.t * bool) list ref = ref [] in
  let defines: (string * (loc * token) list) list ref = ref [] in
  let push newPath =
    stack := (!path, !loc, !stream, !startOfLine)::!stack;
    path := newPath;
    let (newloc, newstream) = streamSource newPath in
    loc := newloc;
    stream := newstream;
    startOfLine := true
  in
  let define x toks =
    defines := (x, toks)::!defines
  in
  let peek() = Stream.peek (!stream) in
  let skip() =
    startOfLine := begin match peek() with Some (_, Eol) -> true | _ -> false end;
    if peek() <> None then Stream.junk (!stream)
  in
  let error msg = raise (ParseException (!loc(), msg)) in
  let next() =
    match peek() with
      Some t -> skip(); t
    | None -> error "Token expected"
  in
  let expect_eol() =
    match peek() with
      None -> ()
    | Some (_, Eol) -> ()
    | _ -> error "End of line expected."
  in
  let expect token =
    match next() with
      (_, t) when t = token -> ()
    | _ ->
      let txt = match token with Eol -> "end of line" | Kwd s -> "'" ^ s ^ "'" in
      error (txt ^ " expected")
  in
  let next_ident() =
    match next() with
      (_, Ident x) -> x
    | _ ->
      error "Identifier expected"
  in
  let rec skip_block() =
    if !startOfLine then
      match next() with
        (l, Kwd "#") ->
        begin
          match next() with
            (_, Kwd "endif") ->
            expect_eol();
            ()
          | (_, Kwd "ifndef") ->
            skip_block();
            skip_block()
          | _ -> skip_block()
        end
      | _ -> skip_block()
    else
    begin
      ignore (next());
      skip_block()
    end
  in
  let rec next_token() =
    let pop() =
      match !stack with
        [] -> None
      | (path0, loc0, stream0, startOfLine0)::stack0 ->
        path := path0;
        loc := loc0;
        stream := stream0;
        stack := stack0;
        startOfLine := startOfLine0;
        next_token()
    in
    if !startOfLine then
      match peek() with
        Some (l, Kwd "#") ->
        begin
          skip();
          match next() with
            (_, Kwd "include") ->
            begin
              match next() with
                (_, String includePath) ->
                expect_eol();
                begin
                  match includePath with
                    "malloc.h" -> ()
                  | "bool.h" -> ()
                  | _ ->
                    let resolvedPath = Filename.concat (Filename.dirname !path) includePath in
                    push resolvedPath
                end;
                next_token()
              | _ ->
                error "String literal expected."
            end
          | (_, Kwd "define") ->
            let x = next_ident() in
            expect_eol();
            define x [];
            next_token()
          | (_, Kwd "ifndef") ->
            let x = next_ident() in
            expect_eol();
            if List.mem_assoc x !defines then
            begin
              skip_block();
              next_token()
            end
            else
              next_token()
          | (_, Kwd "endif") ->
            expect_eol();
            next_token()
          | (l, _) -> error "Expected one of: include, define, ifndef, endif."
        end
      | Some (_, Eol) -> skip(); next_token()
      | None -> pop()
      | t -> skip(); t
    else
      match peek() with
        (Some (l, Ident x)) as t ->
        skip();
        if List.mem_assoc x !defines then next_token() else t
      | Some (_, Eol) -> skip(); next_token()
      | None -> pop()
      | t -> skip(); t
  in
  Stream.from (fun count -> next_token())

type type_ =
    Bool
  | Void
  | IntType
  | Char
  | StructType of string
  | PtrType of type_
  | InductiveType of string

type type_expr =
    ManifestTypeExpr of loc * type_
  | StructTypeExpr of loc * string
  | IdentTypeExpr of loc * string
  | PtrTypeExpr of loc * type_expr

class fieldref (name: string) =
  object
    val mutable range: type_ option = None
    method name = name
    method range = match range with None -> assert false | Some r -> r
    method set_range r = range <- Some r
  end

class predref (name: string) =
  object
    val mutable domain: type_ list option = None
    method name = name
    method domain = match domain with None -> assert false | Some d -> d
    method set_domain d = domain <- Some d
  end

type
  operator = Add | Sub | Le | Lt | Eq | Neq | And | Or | Not
and
  expr =
    True of loc
  | False of loc
  | Var of loc * string
  | Operation of loc * operator * expr list
  | IntLit of loc * int
  | StringLit of loc * string
  | Read of loc * expr * fieldref
  | CallExpr of loc * string * pat list * pat list
  | IfExpr of loc * expr * expr * expr
  | SwitchExpr of loc * expr * switch_expr_clause list
  | SizeofExpr of loc * type_expr
  | FuncNameExpr of string
and
  pat =
    LitPat of expr
  | VarPat of string
  | DummyPat
and
  switch_expr_clause =
    SwitchExprClause of loc * string * string list * expr
and
  stmt =
    PureStmt of loc * stmt
  | Assign of loc * string * expr
  | DeclStmt of loc * type_expr * string * expr
  | Write of loc * expr * fieldref * expr
  | CallStmt of loc * string * expr list
  | IfStmt of loc * expr * stmt list * stmt list
  | SwitchStmt of loc * expr * switch_stmt_clause list
  | Assert of loc * pred
  | Open of loc * string * (loc * string) list * pat list
  | Close of loc * string * (loc * string) list * pat list
  | ReturnStmt of loc * expr option
  | WhileStmt of loc * expr * pred * stmt list
  | BlockStmt of loc * stmt list
and
  switch_stmt_clause =
  | SwitchStmtClause of loc * string * string list * stmt list
and
  pred =
    Access of loc * expr * fieldref * pat
  | CallPred of loc * predref * pat list * pat list
  | ExprPred of loc * expr
  | Sep of loc * pred * pred
  | IfPred of loc * expr * pred * pred
  | SwitchPred of loc * expr * switch_pred_clause list
  | EmpPred of loc
and
  switch_pred_clause =
  | SwitchPredClause of loc * string * string list * pred
and
  func_kind =
  | Regular
  | Fixpoint
  | Lemma
and
  spec =
    Contract of pred * pred
  | FuncTypeSpec of string
and
  decl =
  | Inductive of loc * string * ctor list
  | Struct of loc * string * field list option
  | PredFamilyDecl of loc * string * int * type_expr list
  | PredFamilyInstanceDecl of loc * string * (loc * string) list * (type_expr * string) list * pred
  | Func of loc * func_kind * type_expr option * string * (type_expr * string) list * spec option * stmt list option
  | FuncTypeDecl of loc * type_expr option * string * (type_expr * string) list * (pred * pred)
and
  field =
  | Field of loc * type_expr * string
and
  ctor =
  | Ctor of loc * string * type_expr list

(*
Visual Studio format:
C:\ddd\sss.xyz(123): error VF0001: blah
C:\ddd\sss.xyz(123,456): error VF0001: blah
C:\ddd\sss.xyz(123,456-789): error VF0001: blah
C:\ddd\sss.xyz(123,456-789,123): error VF0001: blah
GNU format:
C:\ddd\sss.xyz:123: error VF0001: blah
C:\ddd\sss.xyz:123.456: error VF0001: blah
C:\ddd\sss.xyz:123.456-789: error VF0001: blah
C:\ddd\sss.xyz:123.456-789.123: error VF0001: blah
See
http://blogs.msdn.com/msbuild/archive/2006/11/03/msbuild-visual-studio-aware-error-messages-and-message-formats.aspx
and
http://www.gnu.org/prep/standards/standards.html#Errors
*)

let string_of_srcpos (p,l,c) = p ^ "(" ^ string_of_int l ^ "," ^ string_of_int c ^ ")"

let string_of_loc ((p1, l1, c1), (p2, l2, c2)) =
  p1 ^ "(" ^ string_of_int l1 ^ "," ^ string_of_int c1 ^
  if p1 = p2 then
    if l1 = l2 then
      if c1 = c2 then
        ""
      else
        "-" ^ string_of_int c2 ^ ")"
    else
      "-" ^ string_of_int l2 ^ "," ^ string_of_int c2 ^ ")"
  else
    ")-" ^ p2 ^ "(" ^ string_of_int l2 ^ "," ^ string_of_int c2 ^ ")"

let expr_loc e =
  match e with
    True l -> l
  | False l -> l
  | Var (l, x) -> l
  | IntLit (l, n) -> l
  | StringLit (l, s) -> l
  | Operation (l, op, es) -> l
  | Read (l, e, f) -> l
  | CallExpr (l, g, pats0, pats) -> l
  | IfExpr (l, e1, e2, e3) -> l
  | SwitchExpr (l, e, secs) -> l
  | SizeofExpr (l, t) -> l

let pred_loc p =
  match p with
    Access (l, e, f, rhs) -> l
  | CallPred (l, g, ies, es) -> l
  | ExprPred (l, e) -> l
  | Sep (l, p1, p2) -> l
  | IfPred (l, e, p1, p2) -> l
  | SwitchPred (l, e, spcs) -> l
  | EmpPred l -> l
  
let stmt_loc s =
  match s with
    PureStmt (l, _) -> l
  | Assign (l, _, _) -> l
  | DeclStmt (l, _, _, _) -> l
  | Write (l, _, _, _) -> l
  | CallStmt (l,  _, _) -> l
  | IfStmt (l, _, _, _) -> l
  | SwitchStmt (l, _, _) -> l
  | Assert (l, _) -> l
  | Open (l, _, _, _) -> l
  | Close (l, _, _, _) -> l
  | ReturnStmt (l, _) -> l
  | WhileStmt (l, _, _, _) -> l
  | BlockStmt (l, ss) -> l

let type_expr_loc t =
  match t with
    ManifestTypeExpr (l, t) -> l
  | StructTypeExpr (l, sn) -> l
  | IdentTypeExpr (l, x) -> l
  | PtrTypeExpr (l, te) -> l

let lexer = make_lexer [
  "struct"; "{"; "}"; "*"; ";"; "int"; "uint"; "bool"; "char"; "true"; "false"; "predicate"; "("; ")"; ","; "requires";
  "->"; "|->"; "&*&"; "inductive"; "="; "|"; "fixpoint"; "switch"; "case"; ":";
  "return"; "+"; "-"; "=="; "?"; "ensures"; "sizeof"; "close"; "void"; "lemma";
  "open"; "if"; "else"; "emp"; "while"; "!="; "invariant"; "<"; "<="; "&&"; "||"; "forall"; "_"; "@*/"; "!"; "string_literal";
  "predicate_family"; "predicate_family_instance"; "typedef"; "#"; "include"; "ifndef"; "define"; "endif"; "assert"
]

let opt p = parser [< v = p >] -> Some v | [< >] -> None
let rec comma_rep p = parser [< '(_, Kwd ","); v = p; vs = comma_rep p >] -> v::vs | [< >] -> []
let rep_comma p = parser [< v = p; vs = comma_rep p >] -> v::vs | [< >] -> []

let read_decls path stream streamSource reportKeyword reportGhostRange =
begin
let tokenStreamSource path = lexer path (streamSource path) reportKeyword in
let (loc, token_stream) = lexer path stream reportKeyword in
let pp_token_stream = preprocess path loc token_stream tokenStreamSource in
let rec parse_decls_eof = parser
  [< ds = parse_decls; _ = Stream.empty >] -> ds
and
  parse_decls = parser
  [< ds0 = parse_decl; ds = parse_decls >] -> ds0@ds
| [< '((p1, _), Kwd "/*@"); ds = parse_pure_decls; '((_, p2), Kwd "@*/"); ds' = parse_decls >] -> let _ = reportGhostRange (p1, p2) in ds @ ds'
| [< >] -> []
and
  parse_decl = parser
  [< '(l, Kwd "struct"); '(_, Ident s); d = parser
    [< '(_, Kwd "{"); fs = parse_fields; '(_, Kwd ";") >] -> Struct (l, s, Some fs)
  | [< '(_, Kwd ";") >] -> Struct (l, s, None)
  | [< t = parse_type_suffix (StructTypeExpr (l, s)); d = parse_func_rest Regular (Some t) >] -> d
  >] -> [d]
| [< '(l, Kwd "typedef"); rt = parse_return_type; '(_, Kwd "("); '(_, Kwd "*"); '(_, Ident g); '(_, Kwd ")"); '(_, Kwd "("); ps = parse_paramlist; '(_, Kwd ";"); c = parse_contract l >] ->
  [FuncTypeDecl (l, rt, g, ps, c)]
| [< t = parse_return_type; d = parse_func_rest Regular t >] -> [d]
and
  parse_pure_decls = parser
  [< ds0 = parse_pure_decl; ds = parse_pure_decls >] -> ds0 @ ds
| [< >] -> []
and
  parse_index_list = parser
  [< '(_, Kwd "("); is = rep_comma (parser [< '(l, Ident i) >] -> (l, i)); '(_, Kwd ")") >] -> is
and
  parse_pure_decl = parser
  [< '(l, Kwd "inductive"); '(_, Ident i); '(_, Kwd "="); cs = (parser [< cs = parse_ctors >] -> cs | [< cs = parse_ctors_suffix >] -> cs); '(_, Kwd ";") >] -> [Inductive (l, i, cs)]
| [< '(l, Kwd "fixpoint"); t = parse_return_type; d = parse_func_rest Fixpoint t >] -> [d]
| [< '(l, Kwd "predicate"); '(_, Ident g); '(_, Kwd "("); ps = parse_paramlist;
     body = (parser [< '(_, Kwd "requires"); p = parse_pred >] -> Some p | [< >] -> None); '(_, Kwd ";");
  >] -> [PredFamilyDecl (l, g, 0, List.map (fun (t, p) -> t) ps)] @ (match body with None -> [] | Some body -> [PredFamilyInstanceDecl (l, g, [], ps, body)])
| [< '(l, Kwd "predicate_family"); '(_, Ident g); '(_, Kwd "("); is = parse_paramlist; '(_, Kwd "("); ps = parse_paramlist; '(_, Kwd ";") >]
  -> [PredFamilyDecl (l, g, List.length is, List.map (fun (t, p) -> t) ps)]
| [< '(l, Kwd "predicate_family_instance"); '(_, Ident g); is = parse_index_list; '(_, Kwd "("); ps = parse_paramlist;
     '(_, Kwd "requires"); p = parse_pred; '(_, Kwd ";"); >] -> [PredFamilyInstanceDecl (l, g, is, ps, p)]
| [< '(l, Kwd "lemma"); t = parse_return_type; d = parse_func_rest Lemma t >] -> [d]
and
  parse_func_rest k t = parser
  [< '(l, Ident g); '(_, Kwd "("); ps = parse_paramlist; f =
    (parser
       [< '(_, Kwd ";"); co = opt parse_spec >] -> Func (l, k, t, g, ps, co, None)
     | [< co = opt parse_spec; ss = parse_block >] -> Func (l, k, t, g, ps, co, Some ss)
    ) >] -> f
and
  parse_ctors_suffix = parser
  [< '(_, Kwd "|"); cs = parse_ctors >] -> cs
| [< >] -> []
and parse_ctors = parser
  [< '(l, Ident cn); ts = (parser [< '(_, Kwd "("); ts = parse_types >] -> ts | [< >] -> []); cs = parse_ctors_suffix >] -> Ctor (l, cn, ts)::cs
and
  parse_types = parser
  [< '(_, Kwd ")") >] -> []
| [< t = parse_type; ts = parse_more_types >] -> t::ts
and
  parse_more_types = parser
  [< '(_, Kwd ","); t = parse_type; ts = parse_more_types >] -> t::ts
| [< '(_, Kwd ")") >] -> []
and
  parse_fields = parser
  [< '(_, Kwd "}") >] -> []
| [< f = parse_field; fs = parse_fields >] -> f::fs
and
  parse_field = parser
  [< t = parse_type; '(l, Ident f); '(_, Kwd ";") >] -> Field (l, t, f)
and
  parse_return_type = parser
  [< t = parse_type >] -> match t with ManifestTypeExpr (_, Void) -> None | _ -> Some t
and
  parse_type = parser
  [< t0 = parse_primary_type; t = parse_type_suffix t0 >] -> t
and
  parse_primary_type = parser
  [< '(l, Kwd "struct"); '(_, Ident s) >] -> StructTypeExpr (l, s)
| [< '(l, Kwd "int") >] -> ManifestTypeExpr (l, IntType)
| [< '(l, Kwd "uint") >] -> IdentTypeExpr (l, "uint")
| [< '(l, Kwd "bool") >] -> ManifestTypeExpr (l, Bool)
| [< '(l, Kwd "void") >] -> ManifestTypeExpr (l, Void)
| [< '(l, Kwd "char") >] -> ManifestTypeExpr (l, Char)
| [< '(l, Ident n) >] -> IdentTypeExpr (l, n)
and
  parse_type_suffix t0 = parser
  [< '(l, Kwd "*"); t = parse_type_suffix (PtrTypeExpr (l, t0)) >] -> t
| [< >] -> t0
and
  parse_paramlist = parser
  [< '(_, Kwd ")") >] -> []
| [< p = parse_param; ps = parse_more_params >] -> p::ps
and
  parse_param = parser
  [< t = parse_type; '(l, Ident pn) >] -> (t, pn)
and
  parse_more_params = parser
  [< '(_, Kwd ","); p = parse_param; ps = parse_more_params >] -> p::ps
| [< '(_, Kwd ")") >] -> []
and
  parse_spec = parser
  [< '((sp1, _), Kwd "/*@"); spec = parser
      [< '(_, Kwd ":"); '(_, Ident fn); '(_, Kwd "@*/") >] -> FuncTypeSpec fn
    | [< '(_, Kwd "requires"); p = parse_pred; '(_, Kwd ";"); '((_, sp2), Kwd "@*/");
         '((sp3, _), Kwd "/*@"); '(_, Kwd "ensures"); q = parse_pred; '(_, Kwd ";"); '((_, sp4), Kwd "@*/")
         >] -> let _ = reportGhostRange (sp1, sp2); reportGhostRange (sp3, sp4) in Contract (p, q)
    >] -> spec
| [< '(_, Kwd "requires"); p = parse_pred; '(_, Kwd ";"); '(_, Kwd "ensures"); q = parse_pred; '(_, Kwd ";") >] -> Contract (p, q)
and
  parse_contract l = parser
  [< spec = parse_spec >] -> match spec with Contract (p, q) -> (p, q) | FuncTypeSpec ftn -> raise (ParseException (l, "Function type specification not allowed here."))
and
  parse_block = parser
  [< '(l, Kwd "{"); ss = parse_stmts; '(_, Kwd "}") >] -> ss
and
  parse_stmts = parser
  [< s = parse_stmt; ss = parse_stmts >] -> s::ss
| [< >] -> []
and
  parse_stmt = parser [< s = parse_stmt0 >] -> stats#stmtParsed; s
and
  parse_stmt0 = parser
  [< '((sp1, _), Kwd "/*@"); s = parse_stmt0; '((_, sp2), Kwd "@*/") >] -> let _ = reportGhostRange (sp1, sp2) in PureStmt ((sp1, sp2), s)
| [< '(l, Kwd "if"); '(_, Kwd "("); e = parse_expr; '(_, Kwd ")"); b1 = parse_block;
     s = parser
       [< '(_, Kwd "else"); b2 = parse_block >] -> IfStmt (l, e, b1, b2)
     | [< >] -> IfStmt (l, e, b1, [])
  >] -> s
| [< '(l, Kwd "switch"); '(_, Kwd "("); e = parse_expr; '(_, Kwd ")"); '(_, Kwd "{"); sscs = parse_switch_stmt_clauses; '(_, Kwd "}") >] -> SwitchStmt (l, e, sscs)
| [< '(l, Kwd "assert"); p = parse_pred; '(_, Kwd ";") >] -> Assert (l, p)
| [< '(l, Kwd "open"); e = parse_expr; '(_, Kwd ";") >] ->
  (match e with
     CallExpr (_, g, es1, es2) -> Open (l, g, List.map (function (LitPat (Var (l, x))) -> (l, x) | e -> raise (ParseException (l, "Index expressions must be identifiers."))) es1, es2)
   | _ -> raise (ParseException (l, "Body of open statement must be call expression.")))
| [< '(l, Kwd "close"); e = parse_expr; '(_, Kwd ";") >] ->
  (match e with
     CallExpr (_, g, es1, es2) -> Close (l, g, List.map (function (LitPat (Var (l, x))) -> (l, x) | e -> raise (ParseException (l, "Index expressions must be identifiers."))) es1, es2)
   | _ -> raise (ParseException (l, "Body of close statement must be call expression.")))
| [< '(l, Kwd "close_instance"); '(_, Ident g); is = parse_index_list; args = parse_patlist; '(_, Kwd ";") >] -> Close (l, g, is, args)
| [< '(l, Kwd "return"); eo = parser [< '(_, Kwd ";") >] -> None | [< e = parse_expr; '(_, Kwd ";") >] -> Some e >] -> ReturnStmt (l, eo)
| [< '(l, Kwd "while"); '(_, Kwd "("); e = parse_expr; '(_, Kwd ")");
     '((sp1, _), Kwd "/*@"); '(_, Kwd "invariant"); p = parse_pred; '(_, Kwd ";"); '((_, sp2), Kwd "@*/");
     b = parse_block >] -> let _ = reportGhostRange (sp1, sp2) in WhileStmt (l, e, p, b)
| [< '(l, Kwd "{"); ss = parse_stmts; '(_, Kwd "}") >] -> BlockStmt (l, ss)
| [< e = parse_expr; s = parser
    [< '(_, Kwd ";") >] -> (match e with CallExpr (l, g, [], es) -> CallStmt (l, g, List.map (function LitPat e -> e) es) | _ -> raise (ParseException (expr_loc e, "An expression used as a statement must be a call expression.")))
  | [< '(l, Kwd "="); rhs = parse_expr; '(_, Kwd ";") >] ->
    (match e with
     | Var (lx, x) -> Assign (l, x, rhs)
     | Read (_, e, f) -> Write (l, e, f, rhs)
     | _ -> raise (ParseException (expr_loc e, "The left-hand side of an assignment must be an identifier or a field dereference expression."))
    )
  >] -> s
| [< te = parse_type; '(lx, Ident x); '(l, Kwd "="); rhs = parse_expr; '(_, Kwd ";") >] -> DeclStmt (l, te, x, rhs)
and
  parse_switch_stmt_clauses = parser
  [< c = parse_switch_stmt_clause; cs = parse_switch_stmt_clauses >] -> c::cs
| [< >] -> []
and
  parse_switch_stmt_clause = parser
  [< '(l, Kwd "case"); '(_, Ident c); pats = (parser [< '(_, Kwd "("); '(lx, Ident x); xs = parse_more_pats >] -> x::xs | [< >] -> []); '(_, Kwd ":"); ss = parse_stmts >] -> SwitchStmtClause (l, c, pats, ss)
and
  parse_more_pats = parser
  [< '(_, Kwd ")") >] -> []
| [< '(_, Kwd ","); '(lx, Ident x); xs = parse_more_pats >] -> x::xs
and
  parse_pred = parser
  [< p0 = parse_pred0; p = parse_sep_rest p0 >] -> p
and
  parse_sep_rest p1 = parser
  [< '(l, Kwd "&*&"); p2 = parse_pred >] -> Sep (l, p1, p2)
| [< >] -> p1
and
  parse_pred0 = parser
  [< '(l, Kwd "switch"); '(_, Kwd "("); e = parse_expr; '(_, Kwd ")"); '(_, Kwd "{"); cs = parse_switch_pred_clauses; '(_, Kwd "}") >] -> SwitchPred (l, e, cs)
| [< '(l, Kwd "emp") >] -> EmpPred l
| [< '(_, Kwd "("); p = parse_pred; '(_, Kwd ")") >] -> p
| [< e = parse_conj_expr; p = parser
    [< '(l, Kwd "|->"); rhs = parse_pattern >] ->
    (match e with
     | Read (_, e, f) -> Access (l, e, f, rhs)
     | _ -> raise (ParseException (expr_loc e, "Left-hand side of access predicate must be a field dereference expression."))
    )
  | [< '(l, Kwd "?"); p1 = parse_pred; '(_, Kwd ":"); p2 = parse_pred >] -> IfPred (l, e, p1, p2)
  | [< >] ->
    (match e with
     | CallExpr (l, g, pats0, pats) -> CallPred (l, new predref g, pats0, pats)
     | _ -> ExprPred (expr_loc e, e)
    )
  >] -> p
and
  parse_pattern = parser
  [< '(_, Kwd "_") >] -> DummyPat
| [< '(_, Kwd "?"); '(lx, Ident x) >] -> VarPat x
| [< e = parse_expr >] -> LitPat e
and
  parse_switch_pred_clauses = parser
  [< c = parse_switch_pred_clause; cs = parse_switch_pred_clauses >] -> c::cs
| [< >] -> []
and
  parse_switch_pred_clause = parser
  [< '(l, Kwd "case"); '(_, Ident c); pats = (parser [< '(_, Kwd "("); '(lx, Ident x); xs = parse_more_pats >] -> x::xs | [< >] -> []); '(_, Kwd ":"); '(_, Kwd "return"); p = parse_pred; '(_, Kwd ";") >] -> SwitchPredClause (l, c, pats, p)
and
  parse_expr = parser
  [< e0 = parse_conj_expr; e = parser
    [< '(l, Kwd "?"); e1 = parse_expr; '(_, Kwd ":"); e2 = parse_expr >] -> IfExpr (l, e0, e1, e2)
  | [< >] -> e0
  >] -> e
and
  parse_conj_expr = parser
  [< e0 = parse_expr_rel; e = parse_expr_conj_rest e0 >] -> e
and
  parse_expr_rel = parser
  [< e0 = parse_expr_arith; e = parse_expr_rel_rest e0 >] -> e
and
  parse_expr_arith = parser
  [< e0 = parse_expr_suffix; e = parse_expr_arith_rest e0 >] -> e
and
  parse_expr_suffix = parser
  [< e0 = parse_expr_primary; e = parse_expr_suffix_rest e0 >] -> e
and
  parse_expr_primary = parser
  [< '(l, Kwd "true") >] -> True l
| [< '(l, Kwd "false") >] -> False l
| [< '(l, Ident x); e = parser
    [< args0 = parse_patlist; e = parser
      [< args = parse_patlist >] -> CallExpr (l, x, args0, args)
    | [< >] -> CallExpr (l, x, [], args0)
    >] -> e
  | [< >] -> Var (l, x)
  >] -> e
| [< '(l, Int i) >] -> IntLit (l, i)
| [< '(l, String s) >] -> StringLit (l, s)
| [< '(l, Kwd "("); e = parse_expr; '(_, Kwd ")") >] -> e
| [< '(l, Kwd "switch"); '(_, Kwd "("); e = parse_expr; '(_, Kwd ")"); '(_, Kwd "{"); cs = parse_switch_expr_clauses; '(_, Kwd "}") >] -> SwitchExpr (l, e, cs)
| [< '(l, Kwd "sizeof"); '(_, Kwd "("); t = parse_type; '(_, Kwd ")") >] -> SizeofExpr (l, t)
| [< '(l, Kwd "!"); e = parse_expr_primary >] -> Operation(l, Not, [e])
and
  parse_switch_expr_clauses = parser
  [< c = parse_switch_expr_clause; cs = parse_switch_expr_clauses >] -> c::cs
| [< >] -> []
and
  parse_switch_expr_clause = parser
  [< '(l, Kwd "case"); '(_, Ident c); pats = (parser [< '(_, Kwd "("); '(lx, Ident x); xs = parse_more_pats >] -> x::xs | [< >] -> []); '(_, Kwd ":"); '(_, Kwd "return"); e = parse_expr; '(_, Kwd ";") >] -> SwitchExprClause (l, c, pats, e)
and
  parse_expr_suffix_rest e0 = parser
  [< '(l, Kwd "->"); '(_, Ident f); e = parse_expr_suffix_rest (Read (l, e0, new fieldref f)) >] -> e
| [< >] -> e0
and
  parse_expr_arith_rest e0 = parser
  [< '(l, Kwd "+"); e1 = parse_expr_suffix; e = parse_expr_arith_rest (Operation (l, Add, [e0; e1])) >] -> e
| [< '(l, Kwd "-"); e1 = parse_expr_suffix; e = parse_expr_arith_rest (Operation (l, Sub, [e0; e1])) >] -> e
| [< >] -> e0
and
  parse_expr_rel_rest e0 = parser
  [< '(l, Kwd "=="); e1 = parse_expr_arith; e = parse_expr_rel_rest (Operation (l, Eq, [e0; e1])) >] -> e
| [< '(l, Kwd "!="); e1 = parse_expr_arith; e = parse_expr_rel_rest (Operation (l, Neq, [e0; e1])) >] -> e
| [< '(l, Kwd "<="); e1 = parse_expr_arith; e = parse_expr_rel_rest (Operation (l, Le, [e0; e1])) >] -> e
| [< '(l, Kwd "<"); e1 = parse_expr_arith; e = parse_expr_rel_rest (Operation (l, Lt, [e0; e1])) >] -> e
| [< >] -> e0
and
  parse_expr_conj_rest e0 = parser
  [< '(l, Kwd "&&"); e1 = parse_expr_rel; e = parse_expr_conj_rest (Operation (l, And, [e0; e1])) >] -> e
| [< '(l, Kwd "||"); e1 = parse_expr_rel; e = parse_expr_conj_rest (Operation (l, Or, [e0; e1])) >] -> e
| [< >] -> e0
and
  parse_arglist = parser
  [< '(l, Kwd "("); es = parser [< '(_, Kwd ")") >] -> [] | [< e0 = parse_expr; es = parse_arglist_rest >] -> e0::es >] -> es
and
  parse_arglist_rest = parser
  [< '(_, Kwd ","); e0 = parse_expr; es = parse_arglist_rest >] -> e0::es
| [< '(_, Kwd ")") >] -> []
and
  parse_patlist = parser
  [< '(l, Kwd "("); pats = parser [< '(_, Kwd ")") >] -> [] | [< pat0 = parse_pattern; pats = parse_patlist_rest >] -> pat0::pats >] -> pats
and
  parse_patlist_rest = parser
  [< '(_, Kwd ","); pat0 = parse_pattern; pats = parse_patlist_rest >] -> pat0::pats
| [< '(_, Kwd ")") >] -> []
in
  try
    parse_decls_eof pp_token_stream
  with Stream.Error msg -> raise (ParseException (loc(), msg))
end

let flatmap f xs = List.concat (List.map f xs)
let rec drop n xs = if n = 0 then xs else drop (n - 1) (List.tl xs)
let rec list_make n x = if n = 0 then [] else x::list_make (n - 1) x

let rec try_assoc x xys =
  match xys with
    [] -> None
  | (x', y)::xys when x' = x -> Some y
  | _::xys -> try_assoc x xys

let rec try_assq x xys =
  match xys with
    [] -> None
  | (x', y)::xys when x' == x -> Some y
  | _::xys -> try_assq x xys

let try_assoc_i x xys =
  let rec iter k xys =
    match xys with
      [] -> None
    | (x', y)::xys when x' = x -> Some (k, y)
    | _::xys -> iter (k + 1) xys
  in
  iter 0 xys

let startswith s s0 =
  String.length s0 <= String.length s && String.sub s 0 (String.length s0) = s0

let lookup env x = List.assoc x env
let update env x t = (x, t)::env
let string_of_env env = String.concat "; " (List.map (function (x, t) -> x ^ " = " ^ t) env)

exception StaticError of loc * string

let static_error l msg = raise (StaticError (l, msg))

type 'termnode heap = (string * 'termnode list) list
type 'termnode env = (string * 'termnode) list
type 'termnode context =
  Assuming of 'termnode
| Executing of 'termnode heap * 'termnode env * loc * string
| PushSubcontext
| PopSubcontext

let string_of_heap h = String.concat " * " (List.map (function (g, ts) -> g ^ "(" ^ (String.concat ", " (List.map (fun t -> t) ts)) ^ ")") h)
  
let string_of_context c =
  match c with
    Assuming t -> "Assuming " ^ t
  | Executing (h, env, l, s) -> "Heap: " ^ string_of_heap h ^ "\nEnv: " ^ string_of_env env ^ "\n" ^ string_of_loc l ^ ": " ^ s
  | PushSubcontext -> "Entering subcontext"
  | PopSubcontext -> "Leaving subcontext"

exception SymbolicExecutionError of string context list * string * loc * string

let zip xs ys =
  let rec iter xs ys zs =
    match (xs, ys) with
      ([], []) -> Some (List.rev zs)
    | (x::xs, y::ys) -> iter xs ys ((x, y)::zs)
    | _ -> None
  in
  iter xs ys []

let verify_program_core (ctxt: ('typenode, 'symbol, 'termnode) Proverapi.context) verbose path stream streamSource reportKeyword reportGhostRange =

  let verbose_print_endline s = if verbose then print_endline s else () in
  let verbose_print_string s = if verbose then print_string s else () in

  let used_ids = ref [] in
  let used_ids_stack = ref ([]: string list list) in
  
  let push() =
    used_ids_stack := !used_ids::!used_ids_stack;
    ctxt#push
  in
  
  let pop() =
    let (ids::t) = !used_ids_stack in
    let _ = used_ids := ids in
    used_ids_stack := t;
    ctxt#pop
  in
  
  let in_temporary_context cont =
    push();
    cont();
    pop()
  in
  
  let mk_symbol s domain range kind =
    let rec iter k =
      let sk = s ^ string_of_int k in
      if List.mem sk !used_ids then iter (k + 1) else (used_ids := sk::!used_ids; sk)
    in
    let name = if List.mem s !used_ids then iter 0 else (used_ids := s::!used_ids; s) in
    ctxt#mk_symbol name domain range kind
  in
  
  let alloc_nullary_ctor j s = mk_symbol s [] ctxt#type_inductive (Proverapi.Ctor j) in
  
  let imap f xs =
    let rec imapi i xs =
      match xs with
        [] -> []
      | x::xs -> f i x::imapi (i + 1) xs
    in
    imapi 0 xs
  in
  
  let ds = read_decls path stream streamSource reportKeyword reportGhostRange in
  
  (* failwith "Done parsing."; *)
  
  let structdeclmap =
    let rec iter sdm ds =
      match ds with
        [] -> sdm
      | Struct (l, sn, fds_opt)::ds ->
        if List.mem_assoc sn sdm then
          static_error l "Duplicate struct name."
        else
          iter ((sn, (l, fds_opt))::sdm) ds
      | _::ds -> iter sdm ds
    in
    iter [] ds
  in
  
  let structmap =
    List.map
      (fun (sn, (l, fds_opt)) ->
         let rec iter fmap fds =
           match fds with
             [] -> (sn, (l, Some (List.rev fmap)))
           | Field (lf, t, f)::fds ->
             if List.mem_assoc f fmap then
               static_error lf "Duplicate field name."
             else (
               let rec check_type te =
                 match te with
                   ManifestTypeExpr (_, IntType) -> IntType
                 | ManifestTypeExpr (_, Char) -> Char
                 | StructTypeExpr (lt, sn) ->
                   if List.mem_assoc sn structdeclmap then
                     StructType sn
                   else
                     static_error lt "No such struct."
                 | PtrTypeExpr (lt, te) -> PtrType (check_type te)
                 | _ -> static_error (type_expr_loc te) "Invalid field type or field type component."
               in
               iter ((f, (lf, check_type t))::fmap) fds
             )
         in
         begin
           match fds_opt with
             Some fds -> iter [] fds
           | None -> (sn, (l, None))
         end
      )
      structdeclmap
  in
  
  let dummy_srcpos = ("prelude", 0, 0) in
  let dummy_loc = (dummy_srcpos, dummy_srcpos) in
  
  let inductivedeclmap =
    let rec iter idm ds =
      match ds with
        [] -> idm
      | (Inductive (l, i, ctors))::ds ->
        if i = "bool" || i = "int" || List.mem_assoc i idm then
          static_error l "Duplicate datatype name."
        else
          iter ((i, (l, ctors))::idm) ds
      | _::ds -> iter idm ds
    in
    iter [("uint", (dummy_loc, []))] ds
  in
  
  let rec check_pure_type te =
    match te with
      ManifestTypeExpr (l, t) -> t
    | IdentTypeExpr (l, id) ->
      if not (List.mem_assoc id inductivedeclmap) then
        static_error l "No such datatype."
      else
        InductiveType id
    | StructTypeExpr (l, sn) ->
      if not (List.mem_assoc sn structmap) then
        static_error l "No such struct."
      else
        StructType sn
    | PtrTypeExpr (l, te) -> PtrType (check_pure_type te)
  in 
  
  let boolt = Bool in
  let intt = IntType in
  let uintt = InductiveType "uint" in
  
  let rec string_of_type t =
    match t with
      Bool -> "bool"
    | Void -> "void"
    | IntType -> "int"
    | Char -> "char"
    | InductiveType i -> i
    | StructType sn -> "struct " ^ sn
    | PtrType t -> string_of_type t ^ " *"
  in
  
  let typenode_of_type t =
    match t with
      Bool -> ctxt#type_bool
    | IntType -> ctxt#type_int
    | Char -> ctxt#type_int
    | InductiveType i -> ctxt#type_inductive
    | StructType sn -> assert false
    | PtrType t -> ctxt#type_int
  in
  
  let functypenames = flatmap (function (FuncTypeDecl (_, _, g, _, _)) -> [g] | _ -> []) ds in
  let isfuncs =
    List.map (fun ftn ->
      let isfuncname = "is_" ^ ftn in
      let domain = [ctxt#type_int] in
      let symb = mk_symbol isfuncname domain ctxt#type_bool Uninterp in
      (isfuncname, (dummy_loc, Bool, [PtrType Void], symb))
    ) functypenames
  in
  
  let (inductivemap, purefuncmap) =
    let rec iter imap pfm ds =
      match ds with
        [] -> (List.rev imap, List.rev pfm)
      | Inductive (l, i, ctors)::ds ->
        let rec citer j ctormap pfm ctors =
          match ctors with
            [] -> iter ((i, (l, List.rev ctormap))::imap) pfm ds
          | Ctor (lc, cn, tes)::ctors ->
            if List.mem_assoc cn pfm then
              static_error lc "Duplicate pure function name."
            else (
              let ts = List.map check_pure_type tes in
              let csym =
                if ts = [] then
                  alloc_nullary_ctor j cn
                else
                  mk_symbol cn (List.map typenode_of_type ts) ctxt#type_inductive (Proverapi.Ctor j)
              in
              citer (j + 1) ((cn, (lc, ts))::ctormap) ((cn, (lc, InductiveType i, ts, csym))::pfm) ctors
            )
        in
        citer 0 [] pfm ctors
      | Func (l, Fixpoint, rto, g, ps, contract, body_opt)::ds ->
        let _ =
          if List.mem_assoc g pfm then static_error l "Duplicate pure function name."
        in
        let rt =
          match rto with
            None -> static_error l "Return type of fixpoint functions cannot be void."
          | Some rt -> (check_pure_type rt)
        in
        let _ =
          match contract with
            None -> ()
          | Some _ -> static_error l "Fixpoint functions cannot have a contract."
        in
        let pmap =
          let rec iter pmap ps =
            match ps with
              [] -> List.rev pmap
            | (te, p)::ps ->
              let _ = if List.mem_assoc p pmap then static_error l "Duplicate parameter name." in
              let t = check_pure_type te in
              iter ((p, t)::pmap) ps
          in
          iter [] ps
        in
        let (index, ctorcount) = 
          match body_opt with
            Some [SwitchStmt (ls, e, cs)] -> (
            let ctorcount = List.length cs in
            match e with
              Var (l, x) -> (
              match try_assoc_i x pmap with
                None -> static_error l "Fixpoint function must switch on a parameter."
              | Some (index, InductiveType i) -> (
                match try_assoc i imap with
                  None -> static_error ls "Switch statement cannot precede inductive declaration."
                | Some (l, ctormap) ->
                  let rec iter ctormap cs =
                    match cs with
                      [] ->
                      let _ = 
                        match ctormap with
                          [] -> ()
                        | (cn, _)::_ ->
                          static_error ls ("Missing case: '" ^ cn ^ "'.")
                      in (index, ctorcount)
                    | SwitchStmtClause (lc, cn, xs, body)::cs -> (
                      match try_assoc cn ctormap with
                        None -> static_error lc "No such constructor."
                      | Some (_, ts) ->
                        let xmap =
                          let rec iter xmap ts xs =
                            match (ts, xs) with
                              ([], []) -> xmap
                            | (t::ts, x::xs) ->
                              let _ = if List.mem_assoc x xmap then static_error lc "Duplicate pattern variable." in
                              iter ((x, t)::xmap) ts xs
                            | ([], _) -> static_error lc "Too many pattern variables."
                            | _ -> static_error lc "Too few pattern variables."
                          in
                          iter [] ts xs
                        in
                        let tenv = xmap @ pmap in
                        let body =
                          match body with
                            [ReturnStmt (_, Some e)] -> e
                          | _ -> static_error lc "Body of switch clause must be a return statement with a result expression."
                        in
                        let rec check e =
                          match e with
                            True l -> boolt
                          | False l -> boolt
                          | Var (l, x) -> (
                            match try_assoc x tenv with
                              None -> (
                                match try_assoc x pfm with
                                  Some (_, t, [], _) -> t
                                | _ -> static_error l "No such variable or constructor."
                              )
                            | Some t -> t
                            )
                          | Operation (l, (Eq | Neq), [e1; e2]) ->
                            let t = check e1 in
                            let _ = checkt e2 t in
                            boolt
                          | Operation (l, (Or | And), [e1; e2]) ->
                            let _ = checkt e1 boolt in
                            let _ = checkt e2 boolt in
                            boolt
                          | Operation (l, Not, [e]) ->
                            let _ = checkt e boolt in
                            boolt
                          | Operation (l, (Le | Lt), [e1; e2]) ->
                            let _ = checkt e1 intt in
                            let _ = checkt e2 intt in
                            boolt
                          | Operation (l, (Add | Sub), [e1; e2]) ->
                            let _ = checkt e1 intt in
                            let _ = checkt e2 intt in
                            intt
                          | IntLit (l, n) -> intt
                          | StringLit (l, s) -> PtrType Char
                          | CallExpr (l, g', [], pats) -> (
                            match try_assoc g' pfm with
                              Some (l, t, ts, _) -> (
                              match zip pats ts with
                                None -> static_error l "Incorrect argument count."
                              | Some pts -> (
                                List.iter (fun (pat, t) ->
                                  match pat with
                                    LitPat e -> checkt e t
                                  | _ -> static_error l "Patterns are not allowed here."
                                ) pts;
                                t
                                )
                              )
                            | None ->
                              if g' = g then
                                match zip pmap pats with
                                  None -> static_error l "Incorrect argument count."
                                | Some pts ->
                                  let _ =
                                    List.iter (fun ((p, t), pat) ->
                                      match pat with
                                        LitPat e -> checkt e t
                                      | _ -> static_error l "Patterns are not allowed here."
                                    ) pts
                                  in
                                  let _ =
                                    match flatmap (function ((p, t), LitPat e) -> if p = x then [e] else []) pts with
                                      [Var (l, x)] when List.mem_assoc x xmap -> ()
                                    | _ -> static_error l "Inductive argument of recursive call must be switch clause pattern variable."
                                  in
                                  rt
                              else
                                static_error l ("No such pure function: " ^ g')
                            )
                          | IfExpr (l, e1, e2, e3) ->
                            let _ = checkt e1 boolt in
                            let t = check e2 in
                            let _ = checkt e3 t in
                            t
                          | e -> static_error (expr_loc e) "Expression form not allowed in fixpoint function body."
                        and checkt e t0 =
                          match (e, t0) with
                            (IntLit (l, 0), PtrType _) -> ()
                          | _ ->
                            let t = check e in
                            if t = t0 then () else static_error (expr_loc e) ("Type mismatch. Actual: " ^ string_of_type t ^ ". Expected: " ^ string_of_type t0 ^ ".")
                        in
                        let _ = checkt body rt in
                        iter (List.remove_assoc cn ctormap) cs
                      )
                  in
                  iter ctormap cs
                )
              | _ -> static_error l "Switch operand is not an inductive value."
              )
            )
          | _ -> static_error l "Body of fixpoint function must be switch statement."
        in
        let fsym = mk_symbol g (List.map (fun (p, t) -> typenode_of_type t) pmap) (typenode_of_type rt) (Proverapi.Fixpoint index) in
        iter imap ((g, (l, rt, List.map (fun (p, t) -> t) pmap, fsym))::pfm) ds
      | _::ds -> iter imap pfm ds
    in
    let indtypemap0 = [("uint", (dummy_loc, [("zero", (dummy_loc, [])); ("succ", (dummy_loc, [uintt]))]))] in
    let purefuncmap0 = 
      [("zero", (dummy_loc, uintt, [], alloc_nullary_ctor 0 "zero"));
       ("succ", (dummy_loc, uintt, [uintt], mk_symbol "succ" [ctxt#type_inductive] ctxt#type_inductive (Proverapi.Ctor 1)))]
    in
    let purefuncmap0 = purefuncmap0 @ isfuncs in
    iter indtypemap0 purefuncmap0 ds
  in
  
  let predfammap = 
    let rec iter pm ds =
      match ds with
        PredFamilyDecl (l, p, arity, tes)::ds ->
        let _ = if List.mem_assoc p pm then static_error l "Duplicate predicate name." in
        let ts = List.map check_pure_type tes in
        iter ((p, (l, arity, ts))::pm) ds
      | _::ds -> iter pm ds
      | [] -> List.rev pm
    in
    let structpreds =
      flatmap
        (fun (sn, (_, fds_opt)) ->
           [("malloc_block_" ^ sn, (dummy_loc, 0, [PtrType (StructType sn)]))] @
           begin
             match fds_opt with
               None -> []
             | Some fds ->
               List.map (fun (fn, (_, t)) -> ("field_" ^ fn, (dummy_loc, 0, [PtrType (StructType sn); t]))) fds
           end
        )
        structmap
    in
    iter structpreds ds
  in

  let funcnames = flatmap (function (Func (l, Regular, rt, g, ps, c, b)) -> [g] | _ -> []) ds in
  
  let check_funcnamelist is = List.map (fun (l, i) -> if not (List.mem i funcnames) then static_error l "No such regular function name."; i) is in
  
  let predinstmap = 
    let rec iter pm ds =
      match ds with
        PredFamilyInstanceDecl (l, p, is, xs, body)::ds ->
        let (arity, ps) =
          match try_assoc p predfammap with
            None -> static_error l "No such predicate family."
          | Some (_, arity, ps) -> (arity, ps)
        in
        if List.length is <> arity then static_error l "Incorrect number of indexes.";
        let pxs =
          match zip ps xs with
            None -> static_error l "Incorrect number of parameters."
          | Some pxs -> pxs
        in
        let fns = check_funcnamelist is in
        let pfns = (p, fns) in
        let _ = if List.mem_assoc pfns pm then static_error l "Duplicate predicate family instance." in
        let rec iter2 xm pxs =
          match pxs with
            [] -> iter ((pfns, (l, List.rev xm, body))::pm) ds
          | (t0, (te, x))::xs ->
            let t = check_pure_type te in
            if t <> t0 then static_error (type_expr_loc te) "Predicate family instance parameter type does not match predicate family parameter type.";
            if List.mem_assoc x xm then static_error l "Duplicate parameter name.";
            iter2 ((x, t)::xm) xs
        in
        iter2 [] pxs
      | _::ds -> iter pm ds
      | [] -> List.rev pm
    in  (* TODO: Include field_xxx predicate bodies in terms of 'range' predicates, so that a field can be turned into a range by opening it. *)
    iter [] ds
  in

  let expect_type l t t0 =
    match (t, t0) with
      (PtrType _, PtrType Void) -> ()
    | (PtrType Void, PtrType _) -> ()
    | _ -> if t = t0 then () else static_error l ("Type mismatch. Actual: " ^ string_of_type t ^ ". Expected: " ^ string_of_type t0 ^ ".")
  in

  let (check_expr, check_expr_t) =
    let funcs tenv =
      let rec check e =
        match e with
          True l -> boolt
        | False l -> boolt
        | Var (l, x) ->
          begin
          match try_assoc x tenv with
            None ->
            begin
              match try_assoc x purefuncmap with
                Some (_, t, [], _) -> t
              | _ ->
                begin
                  if List.mem x funcnames then
                    PtrType Void
                  else
                    static_error l "No such variable or constructor."
                end
            end
          | Some t -> t
          end
        | Operation (l, (Eq | Neq), [e1; e2]) ->
          let t = check e1 in
          let _ = checkt e2 t in
          boolt
        | Operation (l, (Or | And), [e1; e2]) ->
          let _ = checkt e1 boolt in
          let _ = checkt e2 boolt in
          boolt
        | Operation (l, Not, [e]) ->
          let _ = checkt e boolt in
          boolt
        | Operation (l, (Le | Lt), [e1; e2]) ->
          let _ = checkt e1 intt in
          let _ = checkt e2 intt in
          boolt
        | Operation (l, (Add | Sub), [e1; e2]) ->
          let _ = checkt e1 intt in
          let _ = checkt e2 intt in
          intt
        | IntLit (l, n) -> intt
        | StringLit (l, s) -> PtrType Char
        | CallExpr (l, g', [], pats) -> (
          match try_assoc g' purefuncmap with
            Some (l, t, ts, _) -> (
            match zip pats ts with
              None -> static_error l "Incorrect argument count."
            | Some pts -> (
              List.iter (fun (pat, t) ->
                match pat with
                  LitPat e -> checkt e t
                | _ -> static_error l "Patterns are not allowed here."
              ) pts;
              t
              )
            )
          | None -> static_error l "No such pure function."
          )
        | IfExpr (l, e1, e2, e3) ->
          let _ = checkt e1 boolt in
          let t = check e2 in
          let _ = checkt e3 t in
          t
        | FuncNameExpr _ -> PtrType Void
        | e -> static_error (expr_loc e) "Expression form not allowed here."
      and checkt e t0 =
        match (e, t0) with
          (IntLit (l, 0), PtrType _) -> ()
        | _ ->
          let t = check e in expect_type (expr_loc e) t t0
      in
      (check, checkt)
    in
    let check_expr tenv e =
      let (f, _) = funcs tenv in f e
    in
    let check_expr_t tenv e t0 =
      let (_, f) = funcs tenv in f e t0
    in
    (check_expr, check_expr_t)
  in

  let check_pat tenv t p =
    match p with
      LitPat e -> check_expr_t tenv e t; tenv
    | VarPat x -> (x, t)::tenv
    | DummyPat -> tenv
  in
  
  let rec check_pats l tenv ts ps =
    match (ts, ps) with
      ([], []) -> tenv
    | (t::ts, p::ps) ->
      check_pats l (check_pat tenv t p) ts ps
    | ([], _) -> static_error l "Too many patterns"
    | (_, []) -> static_error l "Too few patterns"
  in

  let check_deref l tenv e f =
    let t = check_expr tenv e in
    begin
    match t with
    | PtrType (StructType sn) ->
      begin
      match List.assoc sn structmap with
        (_, Some fds) ->
        begin
          match try_assoc f#name fds with
            None -> static_error l ("No such field in struct '" ^ sn ^ "'.")
          | Some (_, t) -> f#set_range t; t
        end
      | (_, None) -> static_error l ("Invalid dereference; struct type '" ^ sn ^ "' was declared without a body.")
      end
    | _ -> static_error l "Target expression of field dereference should be of type pointer-to-struct."
    end
  in

  let rec check_pred tenv p cont =
    match p with
      Access (l, e, f, v) ->
      let t = check_deref l tenv e f in
      let tenv' = check_pat tenv t v in
      cont tenv'
    | CallPred (l, p, ps0, ps) ->
      begin
      match try_assoc p#name predfammap with
        None -> static_error l "No such predicate."
      | Some (_, arity, xs) ->
        if List.length ps0 <> arity then static_error l "Incorrect number of indexes.";
        let ts = list_make arity (PtrType Void) @ xs in
        begin
        match zip ts (ps0 @ ps) with
          None -> static_error l "Incorrect number of arguments."
        | Some bs ->
          let rec iter tenv bs =
            match bs with
              [] -> p#set_domain ts; cont tenv
            | (t, p)::bs ->
              let tenv = check_pat tenv t p in iter tenv bs
          in
          iter tenv bs
        end
      end
    | ExprPred (l, e) ->
      check_expr_t tenv e boolt; cont tenv
    | Sep (l, p1, p2) ->
      check_pred tenv p1 (fun tenv -> check_pred tenv p2 cont)
    | IfPred (l, e, p1, p2) ->
      check_expr_t tenv e boolt;
      check_pred tenv p1 (fun _ -> ());
      check_pred tenv p2 (fun _ -> ());
      cont tenv
    | SwitchPred (l, e, cs) ->
      let t = check_expr tenv e in
      begin
      match t with
      | InductiveType i ->
        begin
        match try_assoc i inductivemap with
          None -> static_error l "Switch operand is not an inductive value."
        | Some (l, ctormap) ->
          let rec iter ctormap cs =
            match cs with
              [] ->
              let _ = 
                match ctormap with
                  [] -> ()
                | (cn, _)::_ ->
                  static_error l ("Missing case: '" ^ cn ^ "'.")
              in cont tenv
            | SwitchPredClause (lc, cn, xs, body)::cs ->
              begin
              match try_assoc cn ctormap with
                None -> static_error lc "No such constructor."
              | Some (_, ts) ->
                let xmap =
                  let rec iter xmap ts xs =
                    match (ts, xs) with
                      ([], []) -> xmap
                    | (t::ts, x::xs) ->
                      let _ = if List.mem_assoc x xmap then static_error lc "Duplicate pattern variable." in
                      iter ((x, t)::xmap) ts xs
                    | ([], _) -> static_error lc "Too many pattern variables."
                    | _ -> static_error lc "Too few pattern variables."
                  in
                  iter [] ts xs
                in
                let tenv = xmap @ tenv in
                (check_pred tenv body (fun _ -> ());
                iter (List.remove_assoc cn ctormap) cs)
              end
          in
          iter ctormap cs
        end
      | _ -> static_error l "Switch operand is not an inductive value."
      end
    | EmpPred l -> cont tenv
  in

  let _ =
    List.iter
      (
        function
          (pfns, (l, xs, body)) -> check_pred xs body (fun _ -> ())
        | _ -> ()
      )
      predinstmap
  in

  let check_ghost ghostenv l e =
    let rec iter e =
      match e with
        Var (l, x) -> if List.mem x ghostenv then static_error l "Cannot read a ghost variable in a non-pure context."
      | Operation (l, _, es) -> List.iter iter es
      | CallExpr (l, _, [], pats) -> List.iter (function LitPat e -> iter e | _ -> ()) pats
      | IfExpr (l, e1, e2, e3) -> (iter e1; iter e2; iter e3)
      | _ -> ()
    in
    iter e
  in

  let get_unique_var_symb x t = ctxt#mk_app (mk_symbol x [] (typenode_of_type t) Uninterp) [] in
  
  let funcnameterms = List.map (fun fn -> (fn, get_unique_var_symb fn (PtrType Void))) funcnames in

  let rec eval (env: (string * 'termnode) list) e : 'termnode =
    let ev = eval env in
    match e with
      True l -> ctxt#mk_true
    | False l -> ctxt#mk_false
    | Var (l, x) ->
      begin
        match try_assoc x env with
          None ->
          begin
            match try_assoc x purefuncmap with
              None ->
              begin
                match try_assoc x funcnameterms with
                  None -> static_error l "No such variable, constructor, or regular function name."
                | Some t -> t
              end
            | Some (lg, t, [], s) -> ctxt#mk_app s []
            | _ -> static_error l "Missing argument list."
          end
        | Some t -> t
      end
    | IntLit (l, n) -> ctxt#mk_intlit n
    | StringLit (l, s) -> get_unique_var_symb "stringLiteral" (PtrType Char)
    | CallExpr (l, g, [], pats) ->
      begin
        match try_assoc g purefuncmap with
          None -> static_error l "No such pure function."
        | Some (lg, t, pts, s) -> ctxt#mk_app s (List.map (function (LitPat e) -> ev e) pats)
      end
    | Operation (l, And, [e1; e2]) -> ctxt#mk_and (ev e1) (ev e2)
    | Operation (l, Or, [e1; e2]) -> ctxt#mk_or (ev e1) (ev e2)
    | Operation (l, Not, [e]) -> ctxt#mk_not (ev e)
    | IfExpr (l, e1, e2, e3) -> ctxt#mk_ifthenelse (ev e1) (ev e2) (ev e3)
    | Operation (l, Eq, [e1; e2]) -> ctxt#mk_eq (ev e1) (ev e2)
    | Operation (l, Neq, [e1; e2]) -> ctxt#mk_not (ctxt#mk_eq (ev e1) (ev e2))
    | Operation (l, Add, [e1; e2]) -> ctxt#mk_add (ev e1) (ev e2)
    | Operation (l, Sub, [e1; e2]) -> ctxt#mk_sub (ev e1) (ev e2)
    | Operation (l, Le, [e1; e2]) -> ctxt#mk_le (ev e1) (ev e2)
    | Operation (l, Lt, [e1; e2]) -> ctxt#mk_lt (ev e1) (ev e2)
    | Read(l, e, f) -> static_error l "Cannot use field dereference in this context."
    | FuncNameExpr fn -> List.assoc fn funcnameterms
    | _ -> static_error (expr_loc e) "Construct not supported in this position."
  in

  let _ =
    List.iter
    (function
     | Func (l, Fixpoint, t, g, ps, _, Some [SwitchStmt (_, Var (_, x), cs)]) ->
       let rec index_of_param i x0 ps =
         match ps with
           [] -> assert false
         | (tp, x)::ps -> if x = x0 then i else index_of_param (i + 1) x0 ps
       in
       let i = index_of_param 0 x ps in
       let fsym = match List.assoc g purefuncmap with (l, rt, ts, s) -> s in
       let clauses =
         List.map
           (function (SwitchStmtClause (lc, cn, pats, [ReturnStmt (_, Some e)])) ->
              let ctorsym = match List.assoc cn purefuncmap with (l, rt, ts, s) -> s in
              let eval_body gts cts =
                let Some pts = zip ps gts in
                let penv = List.map (fun ((tp, p), t) -> (p, t)) pts in
                let Some patenv = zip pats cts in
                eval (patenv @ penv) e
              in
              (ctorsym, eval_body)
           )
           cs
       in
       ctxt#set_fpclauses fsym i clauses
     | _ -> ()
    )
    ds
  in

  let contextStack = ref ([]: 'termnode context list) in
  
  let push_context msg = let _ = contextStack := msg::!contextStack in () in
  let pop_context () = let _ = let (h::t) = !contextStack in contextStack := t in () in
    
  let with_context msg cont =
    stats#execStep;
    push_context msg;
    cont();
    pop_context();
    ()
  in
  
  (* TODO: To improve performance, push only when branching, i.e. not at every assume. *)
  
  let assume t cont =
    push_context (Assuming t);
    ctxt#push;
    begin
      match ctxt#assume t with
        Unknown -> cont()
      | Unsat -> ()
    end;
    pop_context();
    ctxt#pop
  in
  
  let assume_eq t1 t2 cont = assume (ctxt#mk_eq t1 t2) cont in
  let assume_neq t1 t2 cont = assume (ctxt#mk_not (ctxt#mk_eq t1 t2)) cont in

  let pprint_context_stack cs =
    List.map
      (function
         Assuming t -> Assuming (ctxt#pprint t)
       | Executing (h, env, l, msg) ->
         let h' = List.map (fun (g, ts) -> (g, List.map (fun t -> ctxt#pprint t) ts)) h in
         let env' = List.map (fun (x, t) -> (x, ctxt#pprint t)) env in
         Executing (h', env', l, msg)
       | PushSubcontext -> PushSubcontext
       | PopSubcontext -> PopSubcontext)
      cs
  in

  let assert_term t h env l msg cont =
    if ctxt#query t then
      cont()
    else
      raise (SymbolicExecutionError (pprint_context_stack !contextStack, ctxt#pprint t, l, msg))
  in

  let assert_eq t1 t2 h env l msg cont = assert_term (ctxt#mk_eq t1 t2) h env l msg in
  let assert_neq t1 t2 h env l msg cont = assert_term (ctxt#mk_not (ctxt#mk_eq t1 t2)) h env l msg in
  
  let assert_false h env l msg =
    raise (SymbolicExecutionError (pprint_context_stack !contextStack, "false", l, msg))
  in
  
  let assert_expr env e h env l msg cont = assert_term (eval env e) h env l msg cont in
  
  let success() = () in
  
  let branch cont1 cont2 =
    stats#branch;
    in_temporary_context (fun _ -> cont1());
    in_temporary_context (fun _ -> cont2())
  in
  
  let evalpat ghostenv env pat tp cont =
    match pat with
      LitPat e -> cont ghostenv env (eval env e)
    | VarPat x -> let t = get_unique_var_symb x tp in cont (x::ghostenv) (update env x t) t
    | DummyPat -> let t = get_unique_var_symb "dummy" tp in cont ghostenv env t
  in
  
  let rec evalpats ghostenv env pats tps cont =
    match (pats, tps) with
      ([], []) -> cont ghostenv env []
    | (pat::pats, tp::tps) -> evalpat ghostenv env pat tp (fun ghostenv env t -> evalpats ghostenv env pats tps (fun ghostenv env ts -> cont ghostenv env (t::ts)))
  in

  let assume_field h0 f tp tv cont =
    let rec iter h =
      match h with
        [] -> cont (("field_" ^ f#name, [tp; tv])::h0)
      | (g, [tp'; _])::h when g = "field_" ^ f#name -> assume_neq tp tp' (fun _ -> iter h)
      | _::h -> iter h
    in
    iter h0
  in
  
  let rec assume_pred h ghostenv (env: (string * 'termnode) list) p cont =
    with_context (Executing (h, env, pred_loc p, "Assuming predicate")) (fun _ ->
    let ev = eval env in
    match p with
    | Access (l, e, f, rhs) ->
      let te = ev e in evalpat ghostenv env rhs f#range (fun ghostenv env t -> assume_field h f te t (fun h -> cont h ghostenv env))
    | CallPred (l, g, pats0, pats) -> evalpats ghostenv env (pats0 @ pats) g#domain (fun ghostenv env ts -> cont ((g#name, ts)::h) ghostenv env)
    | ExprPred (l, e) -> assume (ev e) (fun _ -> cont h ghostenv env)
    | Sep (l, p1, p2) -> assume_pred h ghostenv env p1 (fun h ghostenv env -> assume_pred h ghostenv env p2 cont)
    | IfPred (l, e, p1, p2) -> branch (fun _ -> assume (ev e) (fun _ -> assume_pred h ghostenv env p1 cont)) (fun _ -> assume (ctxt#mk_not (ev e)) (fun _ -> assume_pred h ghostenv env p2 cont))
    | SwitchPred (l, e, cs) ->
      let t = ev e in
      let rec iter cs =
        match cs with
          SwitchPredClause (lc, cn, pats, p)::cs ->
          branch
            (fun _ ->
               let (_, _, tps, cs) = List.assoc cn purefuncmap in
               let Some pts = zip pats tps in
               let xts = List.map (fun (x, tp) -> (x, get_unique_var_symb x tp)) pts in
               assume_eq t (ctxt#mk_app cs (List.map (fun (x, t) -> t) xts)) (fun _ -> assume_pred h (pats @ ghostenv) (xts @ env) p cont))
            (fun _ -> iter cs)
        | [] -> success()
      in
      iter cs
    | EmpPred l -> cont h ghostenv env
    )
  in
  
  let definitely_equal t1 t2 =
    ctxt#query (ctxt#mk_eq t1 t2)
  in
  
  let match_chunk ghostenv env g pats (g', ts0) =
    let rec iter ghostenv env pats ts =
      match (pats, ts) with
        (LitPat e::pats, t::ts) -> if definitely_equal (eval env e) t then iter ghostenv env pats ts else None
      | (VarPat x::pats, t::ts) -> iter (x::ghostenv) (update env x t) pats ts
      | (DummyPat::pats, t::ts) -> iter ghostenv env pats ts
      | ([], []) -> Some (ts0, ghostenv, env)
    in
      if g = g' then
        iter ghostenv env pats ts0
      else
        None
  in
  
  let assert_chunk h ghostenv env l g pats cont =
    let rec iter hprefix h =
      match h with
        [] -> []
      | chunk::h ->
        let matches =
          match match_chunk ghostenv env g pats chunk with
            None -> []
          | Some (ts, ghostenv, env) -> [(hprefix @ h, ts, ghostenv, env)]
        in
          matches @ iter (chunk::hprefix) h
    in
    match iter [] h with
      [] -> assert_false h env l ("No matching heap chunks: " ^ g)
(*      
    | [(h, ts, ghostenv, env)] -> cont h ts ghostenv env
    | _ -> assert_false h env l "Multiple matching heap chunks."
*)
    | (h, ts, ghostenv, env)::_ -> cont h ts ghostenv env
  in
  
  let rec assert_pred h ghostenv env p (cont: 'termnode heap -> string list -> 'termnode env -> unit) =
    with_context (Executing (h, env, pred_loc p, "Asserting predicate")) (fun _ ->
    let ev = eval env in
    match p with
    | Access (l, e, f, rhs) ->
      assert_chunk h ghostenv env l ("field_" ^ f#name) [LitPat e; rhs] (fun h ts ghostenv env -> cont h ghostenv env)
    | CallPred (l, g, pats0, pats) ->
      assert_chunk h ghostenv env l g#name (pats0 @ pats) (fun h ts ghostenv env -> cont h ghostenv env)
    | ExprPred (l, e) ->
      assert_expr env e h env l "Expression is false." (fun _ -> cont h ghostenv env)
    | Sep (l, p1, p2) ->
      assert_pred h ghostenv env p1 (fun h ghostenv env -> assert_pred h ghostenv env p2 cont)
    | IfPred (l, e, p1, p2) ->
      branch
        (fun _ ->
           assume (ev e) (fun _ ->
             assert_pred h ghostenv env p1 cont))
        (fun _ ->
           assume (ctxt#mk_not (ev e)) (fun _ ->
             assert_pred h ghostenv env p2 cont))
    | SwitchPred (l, e, cs) ->
      let t = ev e in
      let rec iter cs =
        match cs with
          SwitchPredClause (lc, cn, pats, p)::cs ->
          let (_, _, tps, ctorsym) = List.assoc cn purefuncmap in
          let Some pts = zip pats tps in
          let xts = List.map (fun (x, tp) -> (x, get_unique_var_symb x tp)) pts in
          branch
            (fun _ -> assume_eq t (ctxt#mk_app ctorsym (List.map (fun (x, t) -> t) xts)) (fun _ -> assert_pred h (pats @ ghostenv) (xts @ env) p cont))
            (fun _ -> iter cs)
        | [] -> success()
      in
      iter cs
    | EmpPred l -> cont h ghostenv env
    )
  in

  let rec block_assigned_variables ss =
    match ss with
      [] -> []
    | s::ss -> assigned_variables s @ block_assigned_variables ss
  and assigned_variables s =
    match s with
      Assign (l, x, e) -> [x]
    | IfStmt (l, e, ss1, ss2) -> block_assigned_variables ss1 @ block_assigned_variables ss2
    | SwitchStmt (l, e, cs) -> static_error l "Switch statements inside loops are not supported."
    | WhileStmt (l, e, p, ss) -> block_assigned_variables ss
    | _ -> []
  in
  
  let get_field h t f l cont =
    assert_chunk h [] [("x", t)] l ("field_" ^ f#name) [LitPat (Var (dummy_loc, "x")); VarPat "y"] (fun h ts ghostenv env ->
      cont h (lookup env "y"))
  in
  
  let functypemap =
    let rec iter functypemap ds =
      match ds with
        [] -> List.rev functypemap
      | FuncTypeDecl (l, rt, ftn, xs, (pre, post))::ds ->
        let _ = if List.mem_assoc ftn functypemap then static_error l "Duplicate function type name." in
        let rt = match rt with None -> None | Some rt -> Some (check_pure_type rt) in
        let xmap =
          let rec iter xm xs =
            match xs with
              [] -> List.rev xm
            | (te, x)::xs ->
              if List.mem_assoc x xm then static_error l "Duplicate parameter name.";
              let t = check_pure_type te in
              iter ((x, t)::xm) xs
          in
          iter [] xs
        in
        check_pred (xmap @ [("this", PtrType Void)]) pre (fun tenv ->
          let postmap = match rt with None -> tenv | Some rt -> ("result", rt)::tenv in
          check_pred postmap post (fun _ -> ())
        );
        iter ((ftn, (l, rt, xmap, pre, post))::functypemap) ds
      | _::ds -> iter functypemap ds
    in
    iter [] ds
  in

  let funcmap =
    let rec iter funcmap ds =
      match ds with
        [] -> List.rev funcmap
      | Func (l, k, rt, fn, xs, contract_opt, body)::ds when k <> Fixpoint ->
        let _ = if List.mem_assoc fn funcmap then static_error l "Duplicate function name." in
        let rt = match rt with None -> None | Some rt -> Some (check_pure_type rt) in
        let xmap =
          let rec iter xm xs =
            match xs with
              [] -> List.rev xm
            | (te, x)::xs ->
              if List.mem_assoc x xm then static_error l "Duplicate parameter name.";
              let t = check_pure_type te in
              iter ((x, t)::xm) xs
          in
          iter [] xs
        in
        let (cenv, pre, post) =
          match contract_opt with
            None -> static_error l "Non-fixpoint function must have contract."
          | Some (Contract (pre, post)) ->
            check_pred xmap pre (fun tenv ->
              let postmap = match rt with None -> tenv | Some rt -> ("result", rt)::tenv in
              check_pred postmap post (fun _ -> ())
            );
            (List.map (fun (x, t) -> (x, Var (dummy_loc, x))) xmap, pre, post)
          | Some (FuncTypeSpec ftn) ->
            begin
              match try_assoc ftn functypemap with
                None -> static_error l "No such function type."
              | Some (_, rt0, xmap0, pre, post) ->
                if rt <> rt0 then static_error l "Function return type differs from function type return type.";
                begin
                  match zip xmap xmap0 with
                    None -> static_error l "Function parameter count differs from function type parameter count."
                  | Some bs ->
                    let cenv =
                      List.map
                        (fun ((x, t), (x0, t0)) ->
                         if t <> t0 then static_error l ("Type of parameter '" ^ x ^ "' does not match type of function type parameter '" ^ x0 ^ "'.");
                         (x0, Var (dummy_loc, x))
                        )
                        bs
                      @ [("this", FuncNameExpr fn)]
                    in
                    let (_, _, _, symb) = List.assoc ("is_" ^ ftn) isfuncs in
                    ignore (ctxt#assume (ctxt#mk_eq (ctxt#mk_app symb [List.assoc fn funcnameterms]) ctxt#mk_true));
                    (cenv, pre, post)
                end
            end
        in
        iter ((fn, (l, k, rt, xmap, cenv, pre, post, body))::funcmap) ds
      | _::ds -> iter funcmap ds
    in
    iter [] ds
  in

  let rec verify_stmt pure leminfo sizemap tenv ghostenv h env s tcont =
    stats#stmtExec;
    let l = stmt_loc s in
    let eval env e = let _ = if not pure then check_ghost ghostenv l e in eval env e in
    let ev e = eval env e in
    let cont = tcont sizemap tenv ghostenv in
    let check_assign l x =
      if pure && not (List.mem x ghostenv) then static_error l "Cannot assign to non-ghost variable in pure context."
    in
    let vartp l x = match try_assoc x tenv with None -> static_error l "No such variable." | Some tp -> tp in
    let call_stmt l xo g pats =
      (
      match try_assoc g funcmap with
        None -> (
        match try_assoc g purefuncmap with
          None -> static_error l ("No such function: " ^ g)
        | Some (lg, rt, pts, gs) -> (
          match xo with
            None -> static_error l "Cannot write call of pure function as statement."
          | Some x ->
            let tpx = vartp l x in
            let _ = check_expr_t tenv (CallExpr (l, g, [], pats)) in
            let _ = check_assign l x in
            let ts = List.map (function (LitPat e) -> ev e) pats in
            cont h (update env x (ctxt#mk_app gs ts))
          )
        )
      | Some (_, k, tr, ps, cenv0, pre, post, _) ->
        let _ = if pure && k = Regular then static_error l "Cannot call regular functions in a pure context." in
        let ys = List.map (function (p, t) -> p) ps in
        let _ =
          match zip pats ps with
            None -> static_error l "Incorrect number of arguments."
          | Some bs ->
            List.iter
              (function (LitPat e, (_, tp)) ->
                 check_expr_t tenv e tp;
                 if tp = PtrType Char then   (* TODO: Replace this hack with a proper approach for char arrays (writable ones and readonly ones) *)
                   match e with
                     StringLit _ -> ()
                   | _ -> static_error (expr_loc e) "Argument for parameter of type 'char *' must be string literal."
              ) bs
        in
        let ts = List.map (function (LitPat e) -> ev e) pats in
        let Some env' = zip ys ts in
        let cenv = List.map (fun (x, e) -> (x, eval env' e)) cenv0 in
        with_context PushSubcontext (fun () ->
        assert_pred h ghostenv cenv pre (fun h ghostenv' env' ->
          let _ =
            match leminfo with
              None -> ()
            | Some (lems, g0, indinfo) ->
              if List.mem g lems then
                ()
              else if g = g0 then
                let rec nonempty h =
                  match h with
                    [] -> false
                  | (p, ts)::_ when startswith p "field_" -> true
                  | _::h -> nonempty h
                in
                if nonempty h then
                  ()
                else (
                  match indinfo with
                    None ->
                    with_context (Executing (h, env', l, "Checking recursion termination")) (fun _ ->
                      assert_false h env l "Recursive lemma call does not decrease the heap (no field chunks left) and there is no inductive parameter."
                    )
                  | Some x -> (
                    match try_assq (List.assoc x env') sizemap with
                      Some k when k < 0 -> ()
                    | _ ->
                      with_context (Executing (h, env', l, "Checking recursion termination")) (fun _ ->
                        assert_false h env l "Recursive lemma call does not decrease the heap (no field chunks left) or the inductive parameter."
                      )
                    )
                )
              else
                static_error l "A lemma can call only preceding lemmas or itself."
          in
          let r = match tr with None -> None | Some t -> Some (get_unique_var_symb "result" t, t) in
          let env'' = match r with None -> env' | Some (r, t) -> update env' "result" r in
          assume_pred h ghostenv' env'' post (fun h _ _ ->
            let env =
              match xo with
                None -> env
              | Some x ->
                let tpx = vartp l x in
                let _ = check_assign l x in
                begin
                  match r with
                    None -> static_error l "Call does not return a result."
                  | Some (r, t) -> expect_type l t tpx; update env x r
                end
            in
            with_context PopSubcontext (fun () -> cont h env)
          )
        )
        )
      )
    in
    match s with
      PureStmt (l, s) ->
      verify_stmt true leminfo sizemap tenv ghostenv h env s tcont
    | Assign (l, x, Read (lr, e, f)) ->
      let tpx = vartp l x in
      let _ = expect_type l (check_deref lr tenv e f) tpx in
      let t = ev e in
      let _ = check_assign l x in
      get_field h t f l (fun _ v ->
        cont h (update env x v))
    | Assign (l, x, CallExpr (lc, "malloc", [], args)) ->
      let (lsoe, ltn, tn) =
        match args with
          [LitPat (SizeofExpr (lsoe, StructTypeExpr (ltn, tn)))] -> (lsoe, ltn, tn)
        | _ -> static_error l "malloc argument must be of the form 'sizeof(struct struct_name)'."
      in
      let tpx = vartp l x in
      let _ = check_assign l x in
      let (_, fds_opt) = List.assoc tn structmap in
      let fds =
        match fds_opt with
          Some fds -> fds
        | None -> static_error l "Argument of sizeof cannot be struct type declared without a body."
      in
      let _ =
        match tpx with
          PtrType (StructType sn) when sn = tn -> ()
        | _ -> static_error l ("Type mismatch: actual: '" ^ string_of_type tpx ^ "'; expected: 'struct " ^ tn ^ " *'.")
      in
      let result = get_unique_var_symb "block" tpx in
      let rec iter h fds =
        match fds with
          [] -> cont (h @ [("malloc_block_" ^ tn, [result])]) (update env x result)
        | (f, (lf, t))::fds ->
          let fref = new fieldref f in
          fref#set_range t; assume_field h fref result (get_unique_var_symb "value" t) (fun h -> iter h fds)
      in
      iter h fds
    | CallStmt (l, "free", [Var (lv, x)]) ->
      let _ = if pure then static_error l "Cannot call a non-pure function from a pure context." in
      let (PtrType (StructType tn)) = List.assoc x tenv in
      let [fds_opt] = flatmap (function (Struct (ls, sn, fds)) when sn = tn -> [fds] | _ -> []) ds in
      let fds =
        match fds_opt with
          Some fds -> fds
        | None -> static_error l "Freeing an object of a struct type declared without a body is not supported."
      in
      let rec iter h fds =
        match fds with
          [] -> cont h env
        | (Field (lf, t, f))::fds ->
          let fref = new fieldref f in
          get_field h (lookup env x) fref l (fun h _ -> iter h fds)
      in
      assert_chunk h ghostenv env l ("malloc_block_" ^ tn) [LitPat (Var (lv, x))] (fun h _ _ _ -> iter h fds)
    | Assign (l, x, CallExpr (lc, g, [], pats)) ->
      call_stmt l (Some x) g pats
    | Assign (l, x, e) ->
      let tpx = vartp l x in
      let _ = if pure && not (List.mem x ghostenv) then static_error l "Cannot assign to non-ghost variable in pure context." in
      let _ = check_expr_t tenv e tpx in
      cont h (update env x (ev e))
    | DeclStmt (l, te, x, e) ->
      let t = check_pure_type te in
      let ghostenv = if pure then x::ghostenv else List.filter (fun y -> y <> x) ghostenv in
      verify_stmt pure leminfo sizemap ((x, t)::tenv) ghostenv h env (Assign (l, x, e)) tcont  (* BUGBUG: e should be typechecked outside of the scope of x *)
    | Write (l, e, f, rhs) ->
      let _ = if pure then static_error l "Cannot write in a pure context." in
      let tp = check_deref l tenv e f in
      let _ = check_expr_t tenv rhs tp in
      let t = ev e in
      get_field h t f l (fun h _ ->
        cont (("field_" ^ f#name, [t; ev rhs])::h) env)
    | CallStmt (l, g, es) ->
      call_stmt l None g (List.map (fun e -> LitPat e) es)
    | IfStmt (l, e, ss1, ss2) ->
      let _ = check_expr_t tenv e boolt in
      branch
        (fun _ -> assume (ev e) (fun _ -> verify_cont pure leminfo sizemap tenv ghostenv h env ss1 tcont))
        (fun _ -> assume (ctxt#mk_not (ev e)) (fun _ -> verify_cont pure leminfo sizemap tenv ghostenv h env ss2 tcont))
    | SwitchStmt (l, e, cs) ->
      let tp = check_expr tenv e in
      let (tn, (_, ctormap)) =
        match tp with
          InductiveType i -> (i, List.assoc i inductivemap)
        | _ -> static_error l "Switch statement operand is not an inductive value."
      in
      let t = ev e in
      let rec iter ctors cs =
        match cs with
          [] ->
          begin
          match ctors with
            [] -> success()
          | _ -> static_error l ("Missing clauses: " ^ String.concat ", " ctors)
          end
        | SwitchStmtClause (lc, cn, pats, ss)::cs ->
          let pts =
            match try_assoc cn ctormap with
              None -> static_error lc ("Not a constructor of type " ^ tn)
            | Some (l, pts) -> pts
          in
          let _ = if not (List.mem cn ctors) then static_error lc "Constructor already handled in earlier clause." in
          let ptenv =
            let rec iter ptenv pats pts =
              match (pats, pts) with
                ([], []) -> List.rev ptenv
              | (pat::pats, tp::pts) ->
                if List.mem_assoc pat ptenv then static_error lc "Duplicate pattern variable.";
                iter ((pat, tp)::ptenv) pats pts
              | ([], _) -> static_error lc "Too few arguments."
              | _ -> static_error lc "Too many arguments."
            in
            iter [] pats pts
          in
          let xts = List.map (fun (x, tp) -> (x, get_unique_var_symb x tp)) ptenv in
          let (_, _, _, ctorsym) = List.assoc cn purefuncmap in
          let sizemap =
            match try_assq t sizemap with
              None -> sizemap
            | Some k -> List.map (fun (x, t) -> (t, k - 1)) xts @ sizemap
          in
          branch
            (fun _ -> assume_eq t (ctxt#mk_app ctorsym (List.map (fun (x, t) -> t) xts)) (fun _ -> verify_cont pure leminfo sizemap (ptenv @ tenv) (pats @ ghostenv) h (xts @ env) ss tcont))
            (fun _ -> iter (List.filter (function cn' -> cn' <> cn) ctors) cs)
      in
      iter (List.map (function (cn, _) -> cn) ctormap) cs
    | Assert (l, p) ->
      check_pred tenv p (fun tenv ->
        assert_pred h ghostenv env p (fun _ ghostenv env ->
          tcont sizemap tenv ghostenv h env
        )
      )
    | Open (l, g, is, pats) ->
      let fns = check_funcnamelist is in
      let (ps, p) =
        match try_assoc (g, fns) predinstmap with
          None -> static_error l "No such predicate family instance."
        | Some (l, ps, body) -> (ps, body)
      in
      let tenv' = check_pats l tenv (List.map (fun (x, t) -> t) ps) pats in
      let pats = List.map (fun fn -> LitPat (FuncNameExpr fn)) fns @ pats in
      assert_chunk h ghostenv env l g pats (fun h ts ghostenv env ->
        let ts = drop (List.length fns) ts in
        let ys = List.map (function (p, t) -> p) ps in
        let Some env' = zip ys ts in
        with_context PushSubcontext (fun () ->
          assume_pred h ghostenv env' p (fun h _ _ ->
            with_context PopSubcontext (fun () -> tcont sizemap tenv' ghostenv h env)
          )
        )
      )
    | Close (l, g, is, pats) ->
      let fns = check_funcnamelist is in
      let (ps, p) =
        match try_assoc (g, fns) predinstmap with
          None -> static_error l "No such predicate family instance."
        | Some (l, ps, body) -> (ps, body)
      in
      let _ =
        match zip pats ps with
          None -> static_error l "Wrong number of arguments."
        | Some bs ->
          List.iter (function (LitPat e, (_, tp)) -> check_expr_t tenv e tp) bs
      in
      let ts = List.map (function LitPat e -> ev e) pats in
      let ys = List.map (function (p, t) -> p) ps in
      let Some env' = zip ys ts in
      with_context PushSubcontext (fun () ->
        assert_pred h ghostenv env' p (fun h _ _ ->
          with_context PopSubcontext (fun () -> cont ((g, List.map (fun fn -> List.assoc fn funcnameterms) fns @ ts)::h) env)
        )
      )
    | ReturnStmt (l, Some e) ->
      let tp = match try_assoc "#result" tenv with None -> static_error l "Void function cannot return a value." | Some tp -> tp in
      let _ = if pure && not (List.mem "#result" ghostenv) then static_error l "Cannot return from a regular function in a pure context." in
      let _ = check_expr_t tenv e tp in
      cont h (update env "#result" (ev e))
    | ReturnStmt (l, None) -> cont h env
    | WhileStmt (l, e, p, ss) ->
      let _ = if pure then static_error l "Loops are not yet supported in a pure context." in
      let _ = check_expr_t tenv e boolt in
      check_pred tenv p (fun tenv ->
      let xs = block_assigned_variables ss in
      assert_pred h ghostenv env p (fun h ghostenv env ->
        let ts = List.map (fun x -> get_unique_var_symb x (List.assoc x tenv)) xs in  (* BUG: I assume there is no variable hiding going on here. *)
        let Some bs = zip xs ts in
        let env = bs @ env in
        branch
          (fun _ ->
             assume_pred [] ghostenv env p (fun h ghostenv env ->
               assume (eval env e) (fun _ ->
                 verify_cont pure leminfo sizemap tenv ghostenv h env ss (fun sizemap tenv ghostenv h env ->
                   assert_pred h ghostenv env p (fun h _ _ ->
                     match h with
                       [] -> success()
                     | _ -> assert_false h env l "Loop leaks heap chunks."
                   )
                 )
               )
             )
          )
          (fun _ ->
             assume_pred h ghostenv env p (fun h ghostenv env ->
               assume (ctxt#mk_not (eval env e)) (fun _ ->
                 tcont sizemap tenv ghostenv h env)))
      )
      )
    | BlockStmt (l, ss) ->
      verify_cont pure leminfo sizemap tenv ghostenv h env ss (fun sizemap tenv ghostenv h env -> cont h env)
  and
    verify_cont pure leminfo sizemap tenv ghostenv h env ss cont =
    match ss with
      [] -> cont sizemap tenv ghostenv h env
    | s::ss ->
      with_context (Executing (h, env, stmt_loc s, "Executing statement")) (fun _ ->
        verify_stmt pure leminfo sizemap tenv ghostenv h env s (fun sizemap tenv ghostenv h env ->
          verify_cont pure leminfo sizemap tenv ghostenv h env ss cont
        )
      )
  in

  let rec verify_funcs lems funcs =
    match funcs with
    | [] -> ()
    | (g, (l, k, rt, ps, cenv0, pre, post, Some ss))::funcs ->
      let _ = push() in
      let env = List.map (function (p, t) -> (p, get_unique_var_symb p t)) ps in
      let (sizemap, indinfo) =
        match ss with
          [SwitchStmt (_, Var (_, x), _)] -> (
          match try_assoc x env with
            None -> ([], None)
          | Some t -> ([(t, 0)], Some x)
          )
        | _ -> ([], None)
      in
      let pts = ps in
      let tenv = pts in
      let tenv = List.map (fun (x, e) -> (x, check_expr tenv e)) cenv0 in
      let (tenv, rxs) =
        match rt with
          None -> (tenv, [])
        | Some rt -> (("#result", rt)::tenv, ["#result"])
      in
      let (in_pure_context, leminfo, lems', ghostenv) =
        if k = Lemma then
          (true, Some (lems, g, indinfo), g::lems, List.map (function (p, t) -> p) ps @ rxs)
        else
          (false, None, lems, [])
      in
      check_pred tenv pre (fun tenv ->
      let env = List.map (fun (x, e) -> (x, eval env e)) cenv0 in
      let _ =
        assume_pred [] ghostenv env pre (fun h ghostenv env ->
          verify_cont in_pure_context leminfo sizemap tenv ghostenv h env ss (fun _ _ _ h env' ->
            let get_env_post cont =
              match rt with
                None -> cont env
              | Some t -> (
                match try_assoc "#result" env' with
                  None -> assert_false h env l "Function does not specify a return value."
                | Some t -> cont (update env "result" t)
                )
            in
            get_env_post (fun env_post ->
            assert_pred h ghostenv env_post post (fun h _ _ ->
              with_context (Executing (h, env, l, "Checking emptyness.")) (fun _ ->
              match h with
                [] -> success()
              | _ -> assert_false h env l "Function leaks heap chunks."
              )
            )
            )
          )
        )
      in
      let _ = pop() in
      verify_funcs lems' funcs
      )
    | _::funcs -> verify_funcs lems funcs
  in
  
  verify_funcs [] funcmap

let do_finally tryBlock finallyBlock =
  let result =
    try
      tryBlock()
    with e -> finallyBlock(); raise e
  in
  finallyBlock();
  result

let verify_program_with_stats ctxt print_stats verbose path stream streamSource reportKeyword reportGhostRange =
  do_finally
    (fun () -> verify_program_core ctxt verbose path stream streamSource reportKeyword reportGhostRange)
    (fun () -> if print_stats then stats#printStats)

class virtual prover_client =
  object
    method virtual run: 'typenode 'symbol 'termnode. ('typenode, 'symbol, 'termnode) Proverapi.context -> unit
  end

let prover_table: (string * (prover_client -> unit)) list ref = ref []

let register_prover name f =
  prover_table := (name, f)::!prover_table

let lookup_prover prover =
  match prover with
    None ->
    begin
      match !prover_table with
        [] -> assert false
      | (_, f)::_ -> f
    end
  | Some name ->
    begin
      match try_assoc name !prover_table with
        None -> failwith ("No such prover: " ^ name)
      | Some f -> f
    end
      
let verify_program prover print_stats verbose path stream streamSource reportKeyword reportGhostRange =
  lookup_prover prover
    (object
       method run: 'typenode 'symbol 'termnode. ('typenode, 'symbol, 'termnode) Proverapi.context -> unit =
         fun ctxt -> verify_program_with_stats ctxt print_stats verbose path stream streamSource reportKeyword reportGhostRange
     end)

let remove_dups bs =
  let rec iter bs0 bs =
    match bs with
      [] -> List.rev bs0
    | (x, v)::bs ->
      if List.mem_assoc x bs0 then iter bs0 bs else iter ((x, v)::bs0) bs
  in
  iter [] bs