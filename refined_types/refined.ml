open Expr

module StringSet = Set.Make(String)
module StringMap = Map.Make(String)
module Env = Infer.Env

let log_Z3_input = false


exception Error of string
let error msg = raise (Error msg)


module Z3 = struct
	let info = ref None
	let log = ref ""
	let stack = ref 0

	let is_started () = None != !info

	let stop () =
		match !info with
			| None -> error "Z3 not running"
			| Some(pid, c_in, c_out) ->
				if Unix.getpid () = pid then begin
					let process_status = Unix.close_process (c_in, c_out) in
					begin match process_status with
						| Unix.WEXITED 0 -> ()
						| Unix.WEXITED exit_code -> Printf.printf "Z3 exited with exit code %i\n" exit_code
						| Unix.WSIGNALED signal -> Printf.printf "Z3 was killed by a signal %i\n" signal
						| Unix.WSTOPPED signal -> Printf.printf "Z3 was stopped by a signal %i\n" signal
					end ;
					if (process_status <> Unix.WEXITED 0) || log_Z3_input then begin
						print_endline "\n\nZ3 LOG\n" ;
						print_endline !log
					end ;
					if !stack != 0 then Printf.printf "\nERROR: STACK = %i\n\n" !stack
				end ;
				info := None

	let get_out_channel () =
		match !info with
			| None -> error "Z3 not running"
			| Some (_, _, c_out) -> c_out

	let get_in_channel () =
		match !info with
			| None -> error "Z3 not running"
			| Some (_, c_in, _) -> c_in

	let read () =
		let c_in = get_in_channel () in
		input_line c_in

	let write str =
		let c_out = get_out_channel () in
		output_string c_out str ;
		output_char c_out '\n' ;
		flush c_out ;
		log := !log ^ str ^ "\n"

	let start () =
		if not (is_started ()) then begin
			let c_in, c_out = Unix.open_process "z3 -smt2 -in" in
			info := Some (Unix.getpid (), c_in, c_out) ;
			write "(set-option :global-decls false)" ;
			at_exit stop
		end

	let push () = write "(push)" ; incr stack
	let pop () = write "(pop)\n" ; decr stack

	let push_pop (fn : unit -> unit) : unit =
		push () ;
		begin
			try
				fn ()
			with e -> pop () ; raise e
		end ;
		pop ()
end


let builtins =
	List.fold_left
		(fun names (name, ty_str) -> StringSet.add name names)
		StringSet.empty Core.builtins

let uninterpreted =
	List.fold_left
		(fun names (name, ty_str) ->
			begin match Env.lookup Core.env name with
				| TArrow _ -> ()
				| _ -> error ("uninterpreted symbol " ^ name ^ " is not a function")
			end ;
			StringSet.add name names)
		StringSet.empty Core.uninterpreted

let primitives =
	List.fold_left
		(fun names (name, ty_str) -> StringSet.add name names)
		StringSet.empty Core.primitives





let check_expr_ty expr =
	match get_real_ty expr.ty with
		| TConst "int" | TConst "bool" -> ()
		| _ -> error ("only int or bool, not " ^ string_of_plain_ty expr.ty)

let translate_ty ty =
	match get_real_ty ty with
		| TConst "int" -> "Int"
		| TConst "bool" -> "Bool"
		| _ -> error ("can translate only int or bool, not " ^ string_of_plain_ty ty)

let translate_builtin fn args =
	let args_string = String.concat " " args in
	match fn with
		| "unary-" -> "(- " ^ args_string ^ ")"
		| "!=" -> "(not (= " ^ args_string ^ "))"
		| "==" -> "(= " ^ args_string ^ ")"
		| _ -> "(" ^ fn ^ " " ^ args_string ^ ")"

let rec translate local_env expr =
	check_expr_ty expr ;
	match expr.shape with
	| EVar name ->
			if StringMap.mem name local_env
				then StringMap.find name local_env
				else name
	| EInt i -> string_of_int i
	| EBool b -> string_of_bool b
	| ECall({shape = EVar fn_name; ty = _}, arg_list) ->
			if not (StringSet.mem fn_name builtins) then error "translate NI only builtins" else
			if fn_name == "/" then error "translate NI /" else 
			translate_builtin fn_name (List.map (translate local_env) arg_list)
	| _ -> error "translate NI check_contract"

let declare_var name ty =
	let translated_ty = translate_ty ty in
	Z3.write ("(declare-const " ^ name ^ " " ^ translated_ty ^ ")")


let var_map = Hashtbl.create 5

let declare_new_var ty =
	let var_name = match ty with
		| TConst name -> String.make 1 (String.get name 0)
		| _ -> error "declare_new_var NI types"
	in
	let var_number = try
			Hashtbl.find var_map var_name
		with Not_found -> 0
	in
	Hashtbl.replace var_map var_name (var_number + 1) ;
	let var_name = "_" ^ var_name ^ (string_of_int var_number) in
	declare_var var_name ty ;
	var_name
			

let check_contract local_env contract =
	Z3.push_pop (fun () ->
		Z3.write ("(assert (not " ^ translate local_env contract ^ "))") ;
		Z3.write "(check-sat)") ;
	let answer = Z3.read () in
	if answer <> "unsat" then error ("Z3 returned " ^ answer)

let rec check_expr simple local_env expr = match expr.shape with
	| EVar name -> 
			if StringMap.mem name local_env
				then StringMap.find name local_env
				else name
	| EBool b -> string_of_bool b
	| EInt i -> string_of_int i
	| ECast(expr, ty, Some refined_expr) ->
			let ty = get_real_ty ty in
			if (ty <> t_bool) && (ty <> t_int) then error ("not implemented - check_expr cast " ^ string_of_plain_ty ty) else
			check_contract local_env refined_expr ;
			check_expr simple local_env expr
	| ELet(var_name, value_expr, body_expr) ->
			declare_var var_name value_expr.ty ;
			let translated_value = check_expr false local_env value_expr in
			Z3.write ("(assert (= " ^ var_name ^ " " ^ translated_value ^ "))") ;
			check_expr simple local_env body_expr
	| ECall({shape = EVar fn_name; ty = _}, arg_expr_list) -> begin
			let param_ty_list, refined_return_ty = match Env.lookup Core.env fn_name with
				| TArrow(param_ty_list, refined_return_ty) -> (param_ty_list, refined_return_ty)
				| _ -> assert false
			in
			let rev_translated_arg_list, new_local_env = List.fold_left2
				(fun (rev_translated_arg_list, local_env) (param_ty, name_and_refined_expr) arg_expr ->
					let new_local_env, translated_arg = match name_and_refined_expr with
						| None -> (local_env, check_expr false local_env arg_expr)
						| Some (name, None) ->
								let translated_arg = check_expr true local_env arg_expr in
								(StringMap.add name translated_arg local_env, translated_arg)
						| Some (name, Some refined_expr) ->
								let translated_arg = check_expr true local_env arg_expr in
								let new_local_env = StringMap.add name translated_arg local_env in
								check_contract new_local_env refined_expr ;
								(new_local_env, translated_arg)
					in
					(translated_arg :: rev_translated_arg_list, new_local_env))
				([], local_env) param_ty_list arg_expr_list
			in
			let translated_arg_list = List.rev rev_translated_arg_list in
			let (return_ty, return_name_and_refined_expr) = refined_return_ty in
			if StringSet.mem fn_name builtins then begin
					let translated_expr = translate_builtin fn_name translated_arg_list in
					if simple then
						let var_name = declare_new_var return_ty in
						Z3.write ("(assert (= " ^ var_name ^ " " ^ translated_expr ^ "))") ;
						var_name
					else
						translated_expr
				end
			else
				match return_name_and_refined_expr with
					| None | Some (_, None) -> declare_new_var return_ty
					| Some(name, Some refined_expr) ->
							let var_name = declare_new_var return_ty in
							let translated_refined_expr = check_expr false new_local_env refined_expr in
							Z3.write ("(assert (= " ^ var_name ^ " " ^ translated_refined_expr ^ "))") ;
							var_name
		end
	| _ -> error "not implemented - check_expr"
	

(*
type 'a ty =
	| TConst of name
	| TApp of name * 'a ty list
	| TArrow of ('a refined_ty) list * ('a refined_ty)
	| TVar of ('a tvar) ref

and 'a refined_ty = 'a ty * (name  * 'a option) option

and t_expr_shape =
	| EVar of name
	| EBool of bool
	| EInt of int
	| ECall of t_expr * t_expr list
	| EFun of t_param list * (t_ty * (name * t_expr) option) option * t_expr
	| ELet of name * t_expr * t_expr
	| EIf of t_expr * t_expr * t_expr
	| ECast of t_expr * t_ty * t_expr option

and t_param = name * t_ty * t_expr option
*)

let prove expr =
	Z3.start () ;
	Z3.push_pop (fun () -> ignore (check_expr false StringMap.empty expr)) ;