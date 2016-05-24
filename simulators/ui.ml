(* create the debug user interface *)

open LTerm_widget
open LTerm_geom

open Lwt_react
open CamomileLibraryDyn.Camomile
open LTerm_key
open LTerm_read_line
open LTerm_edit
open LTerm_geom

(* ↑ ↓ ← → *)

module Make(B : HardCaml.Comb.S) = struct

  module Waveterm_waves = HardCamlWaveTerm.Wave.Make(HardCamlWaveTerm.Wave.Bits(B))
  module Waveterm_sim = HardCamlWaveTerm.Sim.Make(B)(Waveterm_waves)
  module Waveterm_ui = HardCamlWaveLTerm.Widget.Make(B)(Waveterm_waves)

  open Waveterm_ui

  let wave_cfg = Waveterm_waves.{ default with wave_cursor=0 }
  let no_state = Waveterm_waves.{ cfg=wave_cfg; waves=[||] }
  let wrap_waves waves = Waveterm_waves.({ cfg=wave_cfg; waves }) 

  let button txt = new button ~brackets:("","") txt 

  let def_zero = "00000000"

  (* 32, 32 bit registers over n_rows *)
  class registers n_rows = object(self)
    inherit t "registers" as super

    method can_focus = false

    val mutable size = { rows=0; cols=0 }
    method size_request = { rows = n_rows; cols = (32 + n_rows - 1) / n_rows }
    method set_allocation r = 
      size <- size_of_rect r;
      super#set_allocation r

    val mutable style = LTerm_style.none
    method update_resources =
      let rc = self#resource_class and resources = self#resources in
      style <- LTerm_resources.get_style rc resources

    val mutable waves = no_state
    val mutable reg_data : Waveterm_waves.t array = 
      let open Waveterm_waves in
      Array.init 32 (fun i -> init 0 (fun _ -> B.empty))
    val mutable reg_data_view : [`lo of string | `hi of string] array = 
      Array.init 32 (fun _ -> `lo def_zero)
    val mutable prev_cursor = 0
    method set_waves w = 
      let open Waveterm_waves in
      (* get the register signals *)
      let is_reg n = try String.length n = 6 && String.sub n 0 4 = "reg_" with _ -> false in
      let reg_num n = try int_of_string (String.sub n 4 2) with _ -> -1 in
      Array.iter 
        (function
          | Data(n, d, _) -> 
            let r = reg_num n in
            if is_reg n && (r <> -1) then begin
              reg_data.(r) <- d
            end
          | _ -> ()) w.waves;
      waves <- w

    method draw ctx focused = 
      let { rows; cols } = LTerm_draw.size ctx in
      LTerm_draw.fill_style ctx style;
      let n_rows = max n_rows (min rows 32) in
      let n_cols = (32 + n_rows - 1) / n_rows in
      let cursor = Waveterm_waves.(waves.cfg.wave_cursor) in
      if prev_cursor <> cursor then begin
        let open Waveterm_waves in
        let open HardCaml.Utils in
        for i=0 to 31 do
          let d0 = reg_data_view.(i) in
          let d1 = 
            try
              hstr_of_bstr Unsigned @@ B.to_bstr @@
              get reg_data.(i) cursor 
            with _ -> def_zero
          in
          match d0 with
          | `lo d0
          | `hi d0 -> 
            reg_data_view.(i) <- if d0 = d1 then `lo d1 else `hi d1
        done;
        prev_cursor <- cursor
      end;
      for r=0 to n_rows-1 do
        for c=0 to n_cols-1 do
          let open Printf in
          let idx = (r * n_cols) + c in
          if idx < 32 then begin
            let c = (c*12) in
            let invert style = LTerm_style.{ style with reverse=Some(true) } in
            LTerm_draw.draw_string ctx r c (sprintf "%.2i" idx);
            (match reg_data_view.(idx) with
            | `lo data -> LTerm_draw.draw_string ~style ctx r (c+3) data;
            | `hi data -> LTerm_draw.draw_string ~style:(invert style) ctx r (c+3) data);
          end
        done
      done

  end

  class asm n_rows = object(self)
    inherit t "asm" as super

    method can_focus = false

    val mutable size = { rows = 0; cols = 0 }
    method size_request = { rows = n_rows; cols = 20 }
    method set_allocation r = 
      size <- size_of_rect r;
      super#set_allocation r

    val mutable style = LTerm_style.none
    method update_resources =
      let rc = self#resource_class and resources = self#resources in
      style <- LTerm_resources.get_style rc resources

    val mutable waves = no_state
    val mutable fet = Waveterm_waves.init 0 (fun _ -> B.empty)
    val mutable dec = Waveterm_waves.init 0 (fun _ -> B.empty)
    val mutable alu = Waveterm_waves.init 0 (fun _ -> B.empty)
    val mutable mem = Waveterm_waves.init 0 (fun _ -> B.empty)
    val mutable com = Waveterm_waves.init 0 (fun _ -> B.empty)
    method set_waves w = 
      let open Waveterm_waves in
      let find name = 
        let rec f i = 
          if i < Array.length w.waves then
            match w.waves.(i) with
            | Data(n, d, _) 
            | Binary(n, d) when n=name -> d
            | _ -> f (i+1)
          else raise Not_found
        in
        f 0
      in
      fet <- find "fet_pc";
      dec <- find "dec_instr";
      alu <- find "alu_instr";
      mem <- find "mem_instr";
      com <- find "com_instr";
      waves <- w

    method draw ctx focused = 
      let open Printf in
      let { rows; cols } = LTerm_draw.size ctx in
      LTerm_draw.fill_style ctx style;
    
      let open Waveterm_waves in
      let cursor = waves.cfg.wave_cursor in
      let pc = 
        try sprintf "pc=%.8lx" (B.to_int32 (get fet cursor))
        with _ -> "???"
      in

      LTerm_draw.draw_string ctx 0 0 ("fet: " ^ pc);

      let asm r l d = 
        let open Riscv.RV32I.T in
        let asm = try pretty (B.to_int32 (get d cursor)) with _ -> "???" in
        LTerm_draw.draw_string ctx r 0 (l ^ ": " ^ asm)
      in

      asm 1 "dec" dec;
      asm 2 "alu" alu;
      asm 3 "mem" mem;
      asm 4 "com" com

      (*for r=0 to rows-1 do
        LTerm_draw.draw_string ctx r 0 "jal r5 r2 r1"
      done*)

  end

  class input_num cols = object(self)
    inherit LTerm_edit.edit_integer
    method! size_request = { rows=1; cols }
  end

  let make_wave_view (waveform : #waveform) waves = 
    let open LTerm_widget in
    let vbox = new vbox in
    let wave_grp = new radiogroup in
    vbox#add ~expand:false (new radiobutton wave_grp "All" `all);
    vbox#add ~expand:false (new radiobutton wave_grp "Regs" `regs);
    vbox#add ~expand:false (new radiobutton wave_grp "Fetch" `fetch);
    vbox#add ~expand:false (new radiobutton wave_grp "Decode" `decode);
    vbox#add ~expand:false (new radiobutton wave_grp "Execute" `execute);
    vbox#add ~expand:false (new radiobutton wave_grp "Memory" `memory);
    vbox#add ~expand:false (new radiobutton wave_grp "Commit" `commit);
    vbox#add (new spacing());
    wave_grp#on_state_change (function
      | Some(x) -> waveform#set_waves @@ wrap_waves @@ List.assoc x waves
      | None -> ());
    vbox

  (* | step [123   ] + | cursor - [123   ] + | <- trans -> |

    step [123   ]    run to cycle number
    step +           increment cycles by number
    cursor [123   ]  goto cycle
    cursor -/+       increment/decrement cursor
    
    TODO: trans: select signals, goto next/prev transition
  *)

  type wave_ctrl = 
    {
      step_num : input_num;
      step_incr : button;
      cursor_num : input_num;
      cursor_incr : button;
      cursor_decr : button;
      hbox : hbox;
      (*trans_incr : button;
      trans_decr : button;*)
    }

  let make_wave_ctrl () = 
    let hbox = new hbox in
    let step_label = new label " step " in
    let step_num = new input_num 12 in
    let step_incr = new button ~brackets:(" "," ") "+" in
    let cursor_label = new label " cursor" in
    let cursor_num = new input_num 12 in
    let cursor_incr = new button ~brackets:(" "," ") "+" in
    let cursor_decr = new button ~brackets:(" "," ") "-" in
    hbox#add ~expand:false step_label;
    hbox#add ~expand:false step_num;
    hbox#add ~expand:false step_incr;
    hbox#add ~expand:false (new vline);
    hbox#add ~expand:false cursor_label;
    hbox#add ~expand:false cursor_decr;
    hbox#add ~expand:false cursor_num;
    hbox#add ~expand:false cursor_incr;
    hbox#add ~expand:false (new vline);
    hbox#add (new spacing ());
    { step_num; step_incr; cursor_num; cursor_incr; cursor_decr; hbox }

  type ui = 
    {
      waveform : waveform;
      wave_ctrl : wave_ctrl;
      registers : registers;
      asm : asm;
      vbox : vbox;
    }

  let make_ui_events ui cycle_count incr_cycles = 
    let maybe d f = function
      | None -> d
      | Some(x) -> f x
    in

    ui.wave_ctrl.step_num#on_event 
      (function 
        | LTerm_event.Key { LTerm_key.code=LTerm_key.Enter } -> begin
          maybe true (fun cycle -> 
            if cycle > !cycle_count then begin
              incr_cycles (Some(cycle - !cycle_count));
              ui.wave_ctrl.step_num#queue_draw; 
            end;
            true) ui.wave_ctrl.step_num#value
        end
        | _ -> false);

    ui.wave_ctrl.step_incr#on_click 
      (fun () -> 
        let cycles = maybe 1 (fun x -> x) ui.wave_ctrl.step_num#value in
          incr_cycles (Some(cycles));
          ui.wave_ctrl.step_num#queue_draw); 

    let set_cursor f = 
      let open Waveterm_waves in
      let cycles = maybe 1 (fun x -> x) ui.wave_ctrl.cursor_num#value in
      let cfg = ui.waveform#get_waves.cfg in
      let max_cycles = Waveterm_ui.R.get_max_cycles ui.waveform#get_waves in
      cfg.wave_cursor <- max 0 (min max_cycles (f cfg.wave_cursor cycles));
      (* set scroll *)
      ui.waveform#waves#hscroll#set_offset cfg.wave_cursor;
      ui.wave_ctrl.cursor_num#queue_draw
    in

    ui.wave_ctrl.cursor_num#on_event
      (function
        | LTerm_event.Key { LTerm_key.code=LTerm_key.Enter } -> begin
          set_cursor (fun _ x -> x);
          true
        end
        | _ -> false);
        
    ui.wave_ctrl.cursor_incr#on_click (fun () -> set_cursor (+));
    ui.wave_ctrl.cursor_decr#on_click (fun () -> set_cursor (-))

  let make_ui waves = 
    let waveform = new waveform ~framed:false () in
    waveform#set_waves @@ wrap_waves @@ List.assoc `all waves;
    let vbox = new LTerm_widget.vbox in
    vbox#add waveform;
    vbox#add ~expand:false (new LTerm_widget.hline);
    let wave_ctrl = make_wave_ctrl () in
    vbox#add ~expand:false wave_ctrl.hbox;
    vbox#add ~expand:false (new hline);
    let hbox = new LTerm_widget.hbox in
    let registers = new registers 8 in
    registers#set_waves @@ wrap_waves @@ List.assoc `all waves;
    hbox#add registers;
    hbox#add ~expand:false (new LTerm_widget.vline);
    let asm = new asm 8 in
    asm#set_waves @@ wrap_waves @@ List.assoc `all waves;
    hbox#add asm;
    hbox#add ~expand:false (new LTerm_widget.vline);
    hbox#add (make_wave_view waveform waves);
    vbox#add ~expand:false hbox;
    { waveform; wave_ctrl; registers; asm; vbox }

end

