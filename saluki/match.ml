open Core_kernel.Std
open Bap.Std
open Spec
open Utilities
open Format
open Option.Monad_infix

(** constraints generated by pattern matchers  *)
type t =
  | Eql of v * var    (** v matches var on lhs    *)
  | Any of t list     (** disjunction of matches  *)
  | All of t list     (** conjunction of matches  *)
[@@deriving variants]

let bot = any []
let top = all []


let any_var v vars : t = match v with
  | 0 -> top
  | v ->
    Set.fold vars ~init:[] ~f:(fun cs var ->
        eql v var :: cs) |>
    any

class matcher : object
  method arg : arg term -> pat -> t
  method phi : phi term -> pat -> t
  method def : def term -> pat -> t
  method jmp : jmp term -> pat -> t
end = object
  method arg _ _ = any []
  method phi _ _ = any []
  method def _ _ = any []
  method jmp _ _ = any []
end

let mem  v : exp -> t =
  let vars v exp =
    any_var v (Exp.free_vars exp) in
  Exp.fold ~init:bot (object
    inherit [t] Bil.visitor
    method! enter_load ~mem ~addr e s eqs =
      match v with
      | `load v -> any [vars v addr; eqs]
      | `store _ -> eqs
    method! enter_store ~mem ~addr ~exp e s eqs =
      match v with
      | `load _ -> eqs
      | `store (p,v) ->
        any [all [vars p addr; vars p exp]; eqs]
  end)

let move = object
  inherit matcher
  method def t r =
    let lhs,rhs = Def.(lhs t, rhs t) in
    match r with
    | Pat.Move (dst,src) ->
      all [eql dst lhs; any_var src (Def.free_vars t)]
    | Pat.Load (dst, ptr) ->
      all [eql dst lhs; mem (`load ptr) rhs]
    | Pat.Store (p,v) ->  mem (`store (p,v)) rhs
    | _ -> bot
end

let jump = object
  inherit matcher
  method jmp t r = match r with
    | Pat.Jump (k,cv,dv) ->
      let sat () : t =
        let conds = Exp.free_vars (Jmp.cond t) in
        let dsts = Set.diff (Jmp.free_vars t) conds in
        all [any_var cv conds; any_var dv dsts] in
      let sat = match k, Jmp.kind t with
        | `call,Call _
        | `goto,Goto _
        | `ret,Ret _
        | `exn,Int _
        | `jmp,_     -> sat
        | _ -> fun _ -> any [] in
      sat ()
    | _ -> any []
end

let args_free_vars =
  Seq.fold ~init:Var.Set.empty ~f:(fun vars arg ->
      let vars = Set.union vars (Arg.rhs arg |> Exp.free_vars) in
      Set.add  vars (Arg.lhs arg))


let any_arg v args : t =
  Seq.to_list_rev args |>
  List.concat_map ~f:(fun arg ->
      let vars =
        Set.add (Arg.rhs arg |> Exp.free_vars) (Arg.lhs arg) in
      [any_var v vars]) |>
  any

let call prog =
  let with_args call f : t =
    let args =
      callee call prog >>= fun sub ->
      let args = Term.enum arg_t sub in
      if Seq.is_empty args then None
      else Some args in
    match args with
    | None -> bot
    | Some args -> f args in

  let match_call_uses call vars : t =
    with_args call (fun args ->
        Seq.zip (Seq.of_list vars) args |>
        Seq.map ~f:(fun (v,a) ->
            any [
              eql v (Arg.lhs a);
              any_var v (Arg.rhs a |> Exp.free_vars)
            ]) |> Seq.to_list_rev |> all) in

  let match_call_def call v : t =
    if v = 0 then top
    else
    with_args call (fun args ->
        Seq.filter args ~f:(fun a -> Arg.intent a = Some Out) |>
        Seq.map ~f:(fun a ->
            let rhs = match Arg.rhs a with
              | Bil.Var var -> eql v var
              | _ -> bot in
            any [eql v (Arg.lhs a); rhs]) |>
        Seq.to_list |> any) in

  object
    inherit matcher
    method jmp t r : t =
      match r, Jmp.kind t with
      | Pat.Call (id,ret,args), Call c
        when call_matches c id -> all [
          match_call_def  c ret;
          match_call_uses c args
        ]
      | Pat.Move (v1,v2), Call c -> all [
          match_call_def c v1;
          with_args c (any_arg v2)
        ]
      | Pat.Wild v, Call c -> with_args c (any_arg v)
      | _ -> bot  (* TODO: add Load and Store pats *)

  end

let wild =
  let any es pat = match pat with
    | Pat.Wild v -> any_var v es
    | _ -> bot in
  object
    inherit matcher
    method def t = any (Def.free_vars t)
    method jmp t = any (Jmp.free_vars t)
    method arg t = any (Exp.free_vars (Arg.rhs t))
    method phi t = any (Phi.free_vars t)
  end


let patterns prog = [wild;jump;move;call prog]


let rec pp ppf = function
  | All [] -> fprintf ppf "T@;"
  | Any [] -> fprintf ppf "F@;"
  | Eql (v,var) -> fprintf ppf "%a = %a@;" V.pp v Var.pp var
  | All constrs -> fprintf ppf "%a@;" (pp_terms "/\\") constrs
  | Any constrs -> fprintf ppf "(%a)@;" (pp_terms "\\/") constrs
and pp_terms sep ppf = function
  | [] -> ()
  | [c] -> pp ppf c
  | c :: cs ->
    fprintf ppf "%a%s@;%a" pp c sep (pp_terms sep) cs
