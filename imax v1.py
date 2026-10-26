# Proyecto 2 - Bases de Datos

# Elaborado por:
#   - Alicia Pedraza Hervoso
#   - Nicolle Rodriguez Lobo
#   - Gabriel Gonzalez Garita

import tkinter as tk

DB_CONFIG = {
    "host": "localhost",
    "port": 5432,
    "dbname": "imax",
    "user": "postgres",
    "password": "",
}


def conectar_bd():
    print("conectar_bd()")


def buscar_funciones(ubicacion, fecha, genero):
    print(f"buscar_funciones({ubicacion}, {fecha}, {genero})")
    return []


def seleccionar_funcion(seleccion):
    print(f"seleccionar_funcion({seleccion})")


def seleccionar_asiento(nombre):
    print(f"seleccionar_asiento({nombre})")


def bloquear_asientos():
    print("bloquear_asientos()")


def liberar_asientos():
    print("liberar_asientos()")


def calcular_total():
    print("calcular_total()")


def procesar_pago(nombre, tarjeta, vencimiento, cvv):
    print("procesar_pago()")


def simular_pago_fallido():
    print("simular_pago_fallido()")


def obtener_entrada():
    print("obtener_entrada()")


def generar_qr():
    print("generar_qr()")


def validar_entrada(codigo, puerta):
    print(f"TODO: validar_entrada({codigo}, {puerta})")
    return "pendiente"

#==============================================================================================================
# Interfaz Grafica

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("IMAX")
        self.geometry("500x450")
        self.mostrar_menu()

    def limpiar(self):
        for widget in self.winfo_children():
            widget.destroy()

    def boton_volver(self):
        tk.Button(self, text="Volver al menu", command=self.mostrar_menu).pack(pady=10)

    # Menu principal
    def mostrar_menu(self):
        self.limpiar()
        tk.Label(self, text="IMAX - Menu principal").pack(pady=10)

        tk.Button(self, text="Cartelera", command=self.mostrar_cartelera).pack(pady=5)
        tk.Button(self, text="Mapa de asientos", command=self.mostrar_asientos).pack(pady=5)
        tk.Button(self, text="Pago", command=self.mostrar_pago).pack(pady=5)
        tk.Button(self, text="Mi entrada (QR)", command=self.mostrar_confirmacion).pack(pady=5)
        tk.Button(self, text="Check-in (puerta)", command=self.mostrar_checkin).pack(pady=5)

    # Cartelera
    def mostrar_cartelera(self):
        self.limpiar()
        tk.Label(self, text="Cartelera").pack(pady=5)

        tk.Label(self, text="Ubicacion").pack()
        ubicacion = tk.Entry(self)
        ubicacion.pack()

        tk.Label(self, text="Fecha").pack()
        fecha = tk.Entry(self)
        fecha.pack()

        tk.Label(self, text="Genero").pack()
        genero = tk.Entry(self)
        genero.pack()

        lista = tk.Listbox(self)
        lista.pack(pady=10)

        def buscar():
            resultados = buscar_funciones(ubicacion.get(), fecha.get(), genero.get())
            lista.delete(0, tk.END)
            for r in resultados:
                lista.insert(tk.END, r)

        tk.Button(self, text="Buscar", command=buscar).pack()
        tk.Button(
            self,
            text="Seleccionar funcion",
            command=lambda: seleccionar_funcion(lista.curselection()),
        ).pack()
        tk.Button(self, text="Ir al mapa de asientos", command=self.mostrar_asientos).pack()
        self.boton_volver()

    # Mapa de asientos
    def mostrar_asientos(self):
        self.limpiar()
        tk.Label(self, text="Mapa de asientos").pack(pady=5)
        tk.Label(self, text="--------- PANTALLA ---------").pack()

        marco = tk.Frame(self)
        marco.pack(pady=10)
        for fila in range(5):
            for col in range(8):
                nombre = f"{chr(65 + fila)}{col + 1}"
                tk.Button(
                    marco,
                    text=nombre,
                    width=4,
                    command=lambda n=nombre: seleccionar_asiento(n),
                ).grid(row=fila, column=col)

        tk.Button(self, text="Confirmar seleccion", command=bloquear_asientos).pack(pady=2)
        tk.Button(self, text="Liberar seleccion", command=liberar_asientos).pack(pady=2)
        tk.Button(self, text="Continuar al pago", command=self.mostrar_pago).pack(pady=2)
        self.boton_volver()

    # Pago
    def mostrar_pago(self):
        self.limpiar()
        tk.Label(self, text="Resumen de compra y pago (simulado)").pack(pady=5)
        tk.Button(self, text="Calcular total", command=calcular_total).pack()

        tk.Label(self, text="Nombre en la tarjeta").pack()
        nombre = tk.Entry(self)
        nombre.pack()

        tk.Label(self, text="Numero de tarjeta").pack()
        tarjeta = tk.Entry(self)
        tarjeta.pack()

        tk.Label(self, text="Vencimiento").pack()
        vencimiento = tk.Entry(self)
        vencimiento.pack()

        tk.Label(self, text="CVV").pack()
        cvv = tk.Entry(self, show="*")
        cvv.pack()

        tk.Button(
            self,
            text="Pagar",
            command=lambda: procesar_pago(
                nombre.get(), tarjeta.get(), vencimiento.get(), cvv.get()
            ),
        ).pack(pady=5)
        tk.Button(self, text="Simular pago fallido", command=simular_pago_fallido).pack()
        tk.Button(self, text="Ir a mi entrada", command=self.mostrar_confirmacion).pack(pady=5)
        self.boton_volver()

    # Confirmacion y QR
    def mostrar_confirmacion(self):
        self.limpiar()
        tk.Label(self, text="Compra / Entrada digital").pack(pady=10)
        tk.Label(self, text="Imagen del QR").pack(pady=20)
        tk.Button(self, text="Ver mi entrada", command=obtener_entrada).pack(pady=5)
        tk.Button(self, text="Generar QR", command=generar_qr).pack(pady=5)
        self.boton_volver()

    # Check-in en puerta
    def mostrar_checkin(self):
        self.limpiar()
        tk.Label(self, text="Check-in en puerta").pack(pady=10)

        tk.Label(self, text="Codigo QR").pack()
        codigo = tk.Entry(self)
        codigo.pack()

        tk.Label(self, text="Puerta / dispositivo").pack()
        puerta = tk.Entry(self)
        puerta.pack()

        resultado = tk.Label(self, text="Resultado: -")
        resultado.pack(pady=10)

        def validar():
            r = validar_entrada(codigo.get(), puerta.get())
            resultado.config(text=f"Resultado: {r}")

        tk.Button(self, text="Validar entrada", command=validar).pack()
        self.boton_volver()


if __name__ == "__main__":
    App().mainloop()