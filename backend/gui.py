# Estudiante: Gabriel González Garita
# Carné: 2024801113
# Proyecto 2 - Cine IMAX
# Interfaz gráfica simple (Tkinter). Se pone dentro de backend/ y se corre con: python gui.py
# Para ver el QR como imagen: pip install qrcode pillow (si no, muestra el texto del código)

import os
import sys
import inspect
import tkinter as tk
from tkinter import ttk, messagebox

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import usuarios, funciones, reservas, compras, boletos, reportes, peliculas
except ImportError as e:
    raise SystemExit(f"Falta un módulo del backend ({e}). gui.py tiene que estar dentro de backend/")

try:
    import qrcode
    from PIL import ImageTk
    HAY_QR = True
except ImportError:
    HAY_QR = False

MAX_ASIENTOS = 6          # RN-04
SEGUNDOS_BLOQUEO = 120    # RN-05
METODOS = ["TARJETA", "PAYPAL", "SINPE", "BILLETERA"]
COLOR = {"DISPONIBLE": "#43a047", "OCUPADO": "#9e9e9e",
         "BLOQUEADO": "#fdd835", "SELECCION": "#1e88e5"}


# ---------------------------------------------------------------
# helpers
# ---------------------------------------------------------------

def a_dict(f):
    # las filas pueden venir como dict o como tupla, las paso todas a dict
    if isinstance(f, dict):
        return f
    if hasattr(f, "keys"):
        return dict(f)
    if isinstance(f, (tuple, list)):
        return {f"c{i}": v for i, v in enumerate(f)}
    return {"valor": f}


def pick(fila, *claves, defecto=None):
    # devuelve el primer campo que exista (por si los nombres de columna cambian)
    for c in claves:
        if c in fila and fila[c] is not None:
            return fila[c]
    return defecto


def como_id(x):
    if hasattr(x, "keys"):
        d = dict(x)
        for k, v in d.items():
            if str(k).startswith("id"):
                return v
        return list(d.values())[0]
    if isinstance(x, (tuple, list)):
        return x[0]
    return x


def conv(txt):
    for tipo in (int, float):
        try:
            return tipo(txt)
        except ValueError:
            pass
    return txt


SIN_VALOR = object()


def buscar_valor(nombre, datos):
    # busca el dato por el nombre del parámetro, así no importa el orden de los argumentos
    if nombre in datos:
        return datos[nombre]
    cands = [k for k in datos if k in nombre]
    if cands:
        return datos[max(cands, key=len)]
    if len(nombre) >= 4:
        cands = [k for k in datos if nombre in k]
        if cands:
            return datos[cands[0]]
    return SIN_VALOR


def llamar(fn, **datos):
    # llama a una función del backend armando los argumentos según su firma
    args = {}
    for nombre, p in inspect.signature(fn).parameters.items():
        if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            continue
        v = buscar_valor(nombre, datos)
        if v is not SIN_VALOR:
            args[nombre] = v
        elif p.default is inspect.Parameter.empty:
            raise RuntimeError(f"{fn.__name__}(): no sé qué pasarle a '{nombre}'")
    return fn(**args)


def llenar_tree(tree, filas):
    tree.delete(*tree.get_children())
    filas = [a_dict(f) for f in filas]
    if not filas:
        tree["columns"] = ()
        return
    cols = list(filas[0].keys())
    tree["columns"] = cols
    for c in cols:
        tree.heading(c, text=c)
        tree.column(c, width=110, anchor="w")
    for i, f in enumerate(filas):
        tree.insert("", "end", iid=str(i), values=[str(f.get(c, "")) for c in cols])


def estado_asiento(a):
    e = pick(a, "estado", "estado_asiento")
    if e is None:
        return "DISPONIBLE" if pick(a, "disponible", defecto=False) else "OCUPADO"
    e = str(e).upper()
    if e.startswith("DISP") or e == "LIBRE":
        return "DISPONIBLE"
    if e.startswith("BLOQ") or e.startswith("RESERV") or e == "TEMPORAL":
        return "BLOQUEADO"
    return "OCUPADO"


def resultado_puerta(res):
    # devuelve (ok, mensaje)
    if isinstance(res, bool):
        return res, "Entrada válida" if res else "Entrada rechazada"
    if isinstance(res, (tuple, list)) and res and isinstance(res[0], bool):
        return res[0], " ".join(str(x) for x in res[1:]) or ("Entrada válida" if res[0] else "Entrada rechazada")
    if isinstance(res, dict):
        for k in ("valido", "ok", "exito", "valida"):
            if k in res:
                return bool(res[k]), str(pick(res, "mensaje", "message", "motivo", defecto=res))
        return True, str(res)
    s = str(res)
    malo = any(w in s.lower() for w in ("rechaz", "ya utiliz", "invalid", "inválid", "fuera"))
    return (not malo), s


# ---------------------------------------------------------------
# pago (simulado)
# ---------------------------------------------------------------

class VentanaPago(tk.Toplevel):
    def __init__(self, tab, id_compra, info):
        super().__init__(tab)
        self.tab = tab
        self.app = tab.app
        self.id_compra = id_compra
        self.restante = SEGUNDOS_BLOQUEO
        self.activo = True
        self.title("Pago")
        self.resizable(False, False)
        self.grab_set()
        self.protocol("WM_DELETE_WINDOW", self.cancelar)

        ttk.Label(self, text="Resumen de compra", font=("Segoe UI", 13, "bold")).grid(
            row=0, column=0, columnspan=2, padx=12, pady=8)
        ttk.Label(self, text="Asientos:").grid(row=1, column=0, sticky="e", padx=6)
        ttk.Label(self, text=str(len(tab.sel))).grid(row=1, column=1, sticky="w")
        total = pick(a_dict(info), "total", "monto", "monto_total")
        if total is not None:
            ttk.Label(self, text="Total:").grid(row=2, column=0, sticky="e", padx=6)
            ttk.Label(self, text=str(total), font=("Segoe UI", 11, "bold")).grid(row=2, column=1, sticky="w")

        ttk.Label(self, text="Método de pago:").grid(row=3, column=0, sticky="e", padx=6, pady=4)
        self.metodo = ttk.Combobox(self, values=METODOS, state="readonly", width=18)
        self.metodo.current(0)
        self.metodo.grid(row=3, column=1, sticky="w")

        # estos datos son de mentiras, no se guardan ni se mandan a ningún lado (RN-09)
        for i, (txt, oculto) in enumerate([("Número de tarjeta", False), ("Vence (MM/AA)", False), ("CVV", True)]):
            ttk.Label(self, text=txt + ":").grid(row=4 + i, column=0, sticky="e", padx=6, pady=2)
            ttk.Entry(self, width=22, show="*" if oculto else "").grid(row=4 + i, column=1, sticky="w")
        ttk.Label(self, text="Pago simulado: estos campos no se guardan.", foreground="#777").grid(
            row=7, column=0, columnspan=2, pady=4)

        self.lbl_t = ttk.Label(self, text="", foreground="#c62828", font=("Segoe UI", 11, "bold"))
        self.lbl_t.grid(row=8, column=0, columnspan=2, pady=4)

        bar = ttk.Frame(self)
        bar.grid(row=9, column=0, columnspan=2, pady=10)
        ttk.Button(bar, text="Pagar (aprobado)", command=lambda: self.pagar(True)).pack(side="left", padx=4)
        ttk.Button(bar, text="Simular rechazo", command=lambda: self.pagar(False)).pack(side="left", padx=4)
        ttk.Button(bar, text="Cancelar", command=self.cancelar).pack(side="left", padx=4)
        self.tick()

    def tick(self):
        if not self.activo:
            return
        self.lbl_t.config(text=f"Asientos bloqueados: {self.restante // 60}:{self.restante % 60:02d}")
        if self.restante <= 0:
            self.activo = False
            uid = self.app.uid
            try:
                llamar(reservas.liberar_vencidas)
            except Exception:
                pass
            try:
                llamar(reservas.cancelar_compra, compra=self.id_compra, usuario=uid)
            except Exception:
                pass
            messagebox.showwarning("Tiempo agotado", "Se venció el bloqueo, los asientos se liberaron.", parent=self)
            self.cerrar()
            return
        self.restante -= 1
        self.after(1000, self.tick)

    def cerrar(self):
        self.activo = False
        self.destroy()
        self.tab.cargar_mapa()

    def cancelar(self):
        try:
            llamar(reservas.cancelar_compra, compra=self.id_compra, usuario=self.app.uid)
        except Exception as e:
            messagebox.showerror("Error", str(e), parent=self)
        self.cerrar()

    def pagar(self, aprobado):
        try:
            llamar(compras.pagar, compra=self.id_compra, usuario=self.app.uid,
                   aprobado=aprobado, metodo=self.metodo.get())
        except Exception as e:
            messagebox.showerror("Error en el pago", str(e), parent=self)
            return
        self.activo = False
        if aprobado:
            messagebox.showinfo("Pago aprobado", "Listo, tus entradas ya están en 'Mis boletos'.", parent=self)
            self.app.tab_boletos.cargar()
            self.app.nb.select(self.app.tab_boletos)
        else:
            messagebox.showwarning("Pago rechazado", "No se cobró nada y los asientos se liberaron.", parent=self)
        self.cerrar()


# ---------------------------------------------------------------
# cartelera + mapa de asientos
# ---------------------------------------------------------------

class TabCartelera(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.todas = []
        self.id_funcion = None
        self.estados = {}
        self.lbls = {}
        self.sel = set()

        top = ttk.Frame(self)
        top.pack(fill="x", padx=8, pady=6)
        ttk.Label(top, text="Buscar (película, cine, fecha, género...):").pack(side="left")
        self.filtro = ttk.Entry(top, width=30)
        self.filtro.pack(side="left", padx=6)
        self.filtro.bind("<KeyRelease>", lambda e: self.filtrar())
        ttk.Button(top, text="Actualizar", command=self.cargar).pack(side="left")

        self.tree = ttk.Treeview(self, show="headings", height=7)
        self.tree.pack(fill="x", padx=8)
        self.tree.bind("<<TreeviewSelect>>", self.al_elegir)

        ttk.Label(self, text="PANTALLA", anchor="center", background="#444", foreground="white").pack(
            fill="x", padx=120, pady=(10, 2))
        self.mapa = ttk.Frame(self)
        self.mapa.pack(pady=4)

        ley = ttk.Frame(self)
        ley.pack()
        for nombre, col in [("Disponible", "DISPONIBLE"), ("Ocupado", "OCUPADO"),
                            ("Bloqueado", "BLOQUEADO"), ("Seleccionado", "SELECCION")]:
            tk.Label(ley, bg=COLOR[col], width=2).pack(side="left", padx=(8, 2))
            ttk.Label(ley, text=nombre).pack(side="left")

        bar = ttk.Frame(self)
        bar.pack(pady=8)
        self.lbl_sel = ttk.Label(bar, text="Asientos seleccionados: 0")
        self.lbl_sel.pack(side="left", padx=10)
        ttk.Button(bar, text="Reservar y pagar", command=self.comprar).pack(side="left")
        self.cargar()

    def cargar(self):
        try:
            self.todas = [a_dict(f) for f in llamar(funciones.cartelera)]
        except Exception as e:
            messagebox.showerror("Error", str(e))
            self.todas = []
        self.filtrar()

    def filtrar(self):
        txt = self.filtro.get().strip().lower()
        vis = [f for f in self.todas if not txt or any(txt in str(v).lower() for v in f.values())]
        llenar_tree(self.tree, vis)
        self.visibles = vis

    def al_elegir(self, _e=None):
        s = self.tree.selection()
        if not s:
            return
        f = self.visibles[int(s[0])]
        self.id_funcion = pick(f, "id_funcion", "funcion_id", "id")
        self.cargar_mapa()

    def cargar_mapa(self):
        for w in self.mapa.winfo_children():
            w.destroy()
        self.lbls, self.estados, self.sel = {}, {}, set()
        self.lbl_sel.config(text="Asientos seleccionados: 0")
        if self.id_funcion is None:
            return
        try:
            asientos = [a_dict(a) for a in llamar(funciones.asientos_disponibilidad, funcion=self.id_funcion)]
        except Exception as e:
            messagebox.showerror("Error", str(e))
            return
        filas = {}
        for a in asientos:
            filas.setdefault(str(pick(a, "fila", "fila_asiento", defecto="?")), []).append(a)

        def num(a):
            try:
                return int(pick(a, "numero", "num_asiento", "columna", defecto=0))
            except (TypeError, ValueError):
                return 0

        for r, nombre in enumerate(sorted(filas)):
            ttk.Label(self.mapa, text=nombre, width=3).grid(row=r, column=0)
            for c, a in enumerate(sorted(filas[nombre], key=num), start=1):
                ida = pick(a, "id_asiento", "asiento_id", "id")
                est = estado_asiento(a)
                self.estados[ida] = est
                l = tk.Label(self.mapa, text=str(num(a)), width=3, bg=COLOR[est], relief="raised", cursor="hand2")
                l.grid(row=r, column=c, padx=1, pady=1)
                l.bind("<Button-1>", lambda e, i=ida: self.click(i))
                self.lbls[ida] = l

    def click(self, ida):
        if self.estados.get(ida) != "DISPONIBLE":
            return
        if ida in self.sel:
            self.sel.remove(ida)
            self.lbls[ida].config(bg=COLOR["DISPONIBLE"])
        elif len(self.sel) >= MAX_ASIENTOS:
            messagebox.showwarning("Límite", f"Máximo {MAX_ASIENTOS} asientos por compra.")
            return
        else:
            self.sel.add(ida)
            self.lbls[ida].config(bg=COLOR["SELECCION"])
        self.lbl_sel.config(text=f"Asientos seleccionados: {len(self.sel)}")

    def comprar(self):
        if not self.sel:
            messagebox.showinfo("Aviso", "Elegí al menos un asiento.")
            return
        uid = self.app.uid
        id_compra = None
        try:
            info = llamar(reservas.crear_compra, usuario=uid, funcion=self.id_funcion)
            id_compra = como_id(info)
            for ida in self.sel:
                llamar(reservas.reservar_asiento, compra=id_compra, funcion=self.id_funcion,
                       asiento=ida, usuario=uid)
        except Exception as e:
            if id_compra is not None:
                try:
                    llamar(reservas.cancelar_compra, compra=id_compra, usuario=uid)
                except Exception:
                    pass
            messagebox.showerror("No se pudo reservar", f"Alguien más pudo haberlo tomado.\n\n{e}")
            self.cargar_mapa()
            return
        VentanaPago(self, id_compra, info)


# ---------------------------------------------------------------
# mis boletos + QR
# ---------------------------------------------------------------

class TabBoletos(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        self.filas = []
        top = ttk.Frame(self)
        top.pack(fill="x", padx=8, pady=6)
        ttk.Button(top, text="Actualizar", command=self.cargar).pack(side="left")
        self.tree = ttk.Treeview(self, show="headings", height=8)
        self.tree.pack(fill="x", padx=8)
        self.tree.bind("<<TreeviewSelect>>", self.al_elegir)
        self.lbl_qr = ttk.Label(self, text="Elegí un boleto para ver su QR", anchor="center")
        self.lbl_qr.pack(pady=15)
        self.cargar()

    def cargar(self):
        try:
            self.filas = [a_dict(f) for f in llamar(boletos.mis_boletos, usuario=self.app.uid)]
        except Exception as e:
            messagebox.showerror("Error", str(e))
            self.filas = []
        llenar_tree(self.tree, self.filas)

    def al_elegir(self, _e=None):
        s = self.tree.selection()
        if not s:
            return
        cod = pick(self.filas[int(s[0])], "codigo_qr", "codigo", "qr")
        if HAY_QR and cod:
            img = qrcode.make(str(cod))
            img = getattr(img, "get_image", lambda: img)().convert("RGB").resize((240, 240))
            self.foto = ImageTk.PhotoImage(img)
            self.lbl_qr.config(image=self.foto, text="")
        else:
            self.lbl_qr.config(image="", text=f"Código: {cod}")


# ---------------------------------------------------------------
# puerta (check-in)
# ---------------------------------------------------------------

class TabPuerta(ttk.Frame):
    def __init__(self, master, app):
        super().__init__(master)
        self.app = app
        f = ttk.Frame(self)
        f.pack(pady=20)
        self.ent = {}
        for i, (txt, k) in enumerate([("Código QR", "codigo"), ("Puerta", "puerta"), ("ID de la función", "funcion")]):
            ttk.Label(f, text=txt + ":").grid(row=i, column=0, sticky="e", padx=6, pady=4)
            e = ttk.Entry(f, width=45)
            e.grid(row=i, column=1, pady=4)
            self.ent[k] = e
        ttk.Button(f, text="Validar entrada", command=self.validar).grid(row=3, column=1, sticky="w", pady=8)
        self.res = tk.Label(self, text="", font=("Segoe UI", 16, "bold"), width=50, height=3)
        self.res.pack(pady=10)

    def validar(self):
        v = {k: e.get().strip() for k, e in self.ent.items()}
        try:
            res = llamar(boletos.validar_codigo, codigo=v["codigo"], puerta=conv(v["puerta"]),
                         funcion=conv(v["funcion"]), operador=self.app.uid, usuario=self.app.uid)
            ok, msg = resultado_puerta(res)
        except Exception as e:
            ok, msg = False, str(e)
        self.res.config(text=("✔ " if ok else "✘ ") + msg, bg="#c8e6c9" if ok else "#ffcdd2",
                        fg="#1b5e20" if ok else "#b71c1c")


# ---------------------------------------------------------------
# panel genérico: reportes y gestión (arma el formulario según la función)
# ---------------------------------------------------------------

class PanelGenerico(ttk.Frame):
    def __init__(self, master, app, funcs):
        super().__init__(master)
        self.app = app
        self.funcs = funcs
        top = ttk.Frame(self)
        top.pack(fill="x", padx=8, pady=6)
        ttk.Label(top, text="Operación:").pack(side="left")
        self.cb = ttk.Combobox(top, values=sorted(funcs), state="readonly", width=45)
        self.cb.pack(side="left", padx=6)
        self.cb.bind("<<ComboboxSelected>>", self.armar_form)
        ttk.Button(top, text="Ejecutar", command=self.ejecutar).pack(side="left")
        self.form = ttk.Frame(self)
        self.form.pack(fill="x", padx=8)
        self.msg = ttk.Label(self, text="")
        self.msg.pack(anchor="w", padx=8, pady=4)
        self.tree = ttk.Treeview(self, show="headings", height=14)
        self.tree.pack(fill="both", expand=True, padx=8, pady=4)
        self.entradas = {}

    def armar_form(self, _e=None):
        for w in self.form.winfo_children():
            w.destroy()
        self.entradas = {}
        fn = self.funcs[self.cb.get()]
        for i, (nombre, p) in enumerate(inspect.signature(fn).parameters.items()):
            if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
                continue
            ttk.Label(self.form, text=nombre + ":").grid(row=i, column=0, sticky="e", padx=4, pady=2)
            e = ttk.Entry(self.form, width=40)
            e.grid(row=i, column=1, sticky="w")
            if "usuario" in nombre or "admin" in nombre:
                e.insert(0, str(self.app.uid))
            self.entradas[nombre] = (e, p)

    def ejecutar(self):
        if not self.cb.get():
            return
        fn = self.funcs[self.cb.get()]
        kw = {}
        for nombre, (e, p) in self.entradas.items():
            txt = e.get().strip()
            if txt:
                kw[nombre] = conv(txt)
            elif p.default is inspect.Parameter.empty:
                kw[nombre] = None
        try:
            res = fn(**kw)
        except Exception as ex:
            messagebox.showerror("Error", str(ex))
            return
        self.msg.config(text="")
        if isinstance(res, list):
            llenar_tree(self.tree, res)
        elif res is not None and hasattr(res, "keys"):
            llenar_tree(self.tree, [res])
        else:
            llenar_tree(self.tree, [])
            self.msg.config(text="Resultado: " + ("listo" if res is None else str(res)))


def funciones_de(mod):
    return {f"{mod.__name__}.{n}": f for n, f in inspect.getmembers(mod, inspect.isfunction)
            if f.__module__ == mod.__name__ and not n.startswith("_")}


# ---------------------------------------------------------------
# ventana principal
# ---------------------------------------------------------------

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("IMAX - Sistema de boletos")
        self.geometry("1000x700")
        ttk.Style(self).theme_use("clam")
        self.uid = None
        self.usuario = {}
        self.pantalla_login()

    def limpiar(self):
        for w in self.winfo_children():
            w.destroy()

    def pantalla_login(self):
        self.limpiar()
        f = ttk.Frame(self)
        f.place(relx=0.5, rely=0.4, anchor="center")
        ttk.Label(f, text="IMAX", font=("Segoe UI", 28, "bold")).grid(row=0, column=0, columnspan=2, pady=10)
        ttk.Label(f, text="Correo:").grid(row=1, column=0, sticky="e", pady=4)
        self.e_correo = ttk.Entry(f, width=30)
        self.e_correo.grid(row=1, column=1)
        ttk.Label(f, text="Contraseña:").grid(row=2, column=0, sticky="e", pady=4)
        self.e_clave = ttk.Entry(f, width=30, show="*")
        self.e_clave.grid(row=2, column=1)
        self.e_clave.bind("<Return>", lambda e: self.entrar())
        ttk.Button(f, text="Entrar", command=self.entrar).grid(row=3, column=1, sticky="e", pady=10)

    def entrar(self):
        c, p = self.e_correo.get().strip(), self.e_clave.get()
        try:
            res = llamar(usuarios.iniciar_sesion, correo=c, email=c, usuario=c,
                         contrasena=p, clave=p, password=p)
        except Exception as e:
            messagebox.showerror("Error", str(e))
            return
        if not res:
            messagebox.showerror("Login", "Correo o contraseña incorrectos.")
            return
        if hasattr(res, "keys"):
            self.usuario = dict(res)
        elif isinstance(res, (tuple, list)):
            self.usuario = {"id_usuario": res[0]}
        else:
            self.usuario = {"id_usuario": res}
        self.uid = pick(self.usuario, "id_usuario", "id", defecto=como_id(res))
        self.pantalla_principal()

    def pantalla_principal(self):
        self.limpiar()
        rol = str(pick(self.usuario, "rol", "nombre_rol", "rol_nombre", defecto="")).lower()
        todo = rol == "" or "admin" in rol or "gerente" in rol
        nombre = pick(self.usuario, "nombre", "correo", defecto=self.uid)

        bar = ttk.Frame(self)
        bar.pack(fill="x", padx=8, pady=4)
        ttk.Label(bar, text=f"Usuario: {nombre}   |   Rol: {rol or 'sin definir'}").pack(side="left")
        ttk.Button(bar, text="Cerrar sesión", command=self.pantalla_login).pack(side="right")

        self.nb = ttk.Notebook(self)
        self.nb.pack(fill="both", expand=True, padx=8, pady=4)
        self.tab_boletos = None

        if todo or "cliente" in rol or "taquill" in rol:
            self.tab_cartelera = TabCartelera(self.nb, self)
            self.tab_boletos = TabBoletos(self.nb, self)
            self.nb.add(self.tab_cartelera, text="Cartelera y compra")
            self.nb.add(self.tab_boletos, text="Mis boletos")
        if todo or "operador" in rol or "puerta" in rol:
            self.nb.add(TabPuerta(self.nb, self), text="Puerta (check-in)")
        if todo or "contador" in rol:
            self.nb.add(PanelGenerico(self.nb, self, funciones_de(reportes)), text="Reportes")
        if todo:
            gest = funciones_de(peliculas)
            if hasattr(funciones, "crear_funcion"):
                gest["funciones.crear_funcion"] = funciones.crear_funcion
            self.nb.add(PanelGenerico(self.nb, self, gest), text="Gestión (admin)")


if __name__ == "__main__":
    App().mainloop()
