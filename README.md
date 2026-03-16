# EnhancedRpc

Uma camada RPC para Godot 4 construída sobre ENet. Em vez de depender do sistema automático do Godot, você passa os argumentos diretamente como um `Array` — simples, sem overhead e sem surpresas.

## Como funciona

O sistema tem dois tipos de chamada:

- **`exec`** — envia uma chamada e não espera resposta
- **`invoke`** — envia uma chamada e aguarda um retorno com `await`

Em ambos os casos, você passa os argumentos como um `Array`. O método registrado no outro lado os recebe como parâmetros normais da função.

## Instalação

Baixe e cole a pasta dentro de `addons/` no seu projeto:

```
res://
└── addons/
    └── enhanced_rpc/
        ├── base.gd
        ├── client.gd
        └── server.gd
```

Depois ative o plugin em **Projeto → Configurações do Projeto → Plugins**.

## Primeiros passos

### Servidor

```gdscript
var server := EnhancedServer.new()

func _ready() -> void:
    var peer := ENetMultiplayerPeer.new()
    peer.create_server(7777)
    server.start(peer)

    # Registre os métodos que o cliente pode chamar
    server.register_methods("game", [mover])

func mover(x: float, y: float) -> void:
    print("Peer %d quer mover para (%.1f, %.1f)" % [server.get_sender_id(), x, y])

func _process(_delta: float) -> void:
    server.poll()
```

### Cliente

```gdscript
var client := EnhancedClient.new()

func _ready() -> void:
    var peer := ENetMultiplayerPeer.new()
    peer.create_client("127.0.0.1", 7777)
    client.start(peer)

func _process(_delta: float) -> void:
    client.poll()
```

## Enviando dados

### exec — sem retorno

Passe o caminho `"escopo.metodo"` e um `Array` com os argumentos:

```gdscript
client.exec("game.mover", [x, y])
```

Se o método não tiver argumentos, o segundo parâmetro é opcional:

```gdscript
client.exec("game.ping")
```

### invoke — com retorno

Funciona igual ao `exec`, mas retorna a `Variant` devolvida pelo método remoto:

```gdscript
var hp: int = await client.invoke("game.get_hp", [player_id])
```

O método registrado no servidor só precisa ter um `return` normal:

```gdscript
server.register_methods("game", [get_hp])

func get_hp(player_id: int) -> int:
    return jogadores[player_id].hp
```

## Obtendo o remetente

Para saber qual peer fez a chamada, use `get_sender_id()` dentro do método registrado:

```gdscript
func atacar(alvo_id: int) -> void:
    print("Peer %d atacou o peer %d!" % [server.get_sender_id(), alvo_id])
```

## Broadcast

O servidor pode enviar para mais de um peer ao mesmo tempo. O pacote é serializado **uma única vez** independente de quantos peers receberem.

```gdscript
# Peer específico
server.exec(peer_id, "game.spawn", [entidade_id])

# Lista de peers
server.exec([peer_a, peer_b], "game.spawn", [entidade_id])

# Filtrado por uma condição
server.exec(
    func(id: int) -> bool: return time[id] == Time.AZUL,
    "game.spawn",
    [entidade_id]
)

# Broadcast para todos
server.exec(null, "game.spawn", [entidade_id])
```

## Registrando métodos

```gdscript
server.register_methods("escopo", [nome_do_metodo])
server.unregister_methods("escopo", [nome_do_metodo])
```

O nome do escopo e o nome da função formam juntos o identificador da chamada (`"escopo.metodo"`). Por isso **lambdas não são permitidas** — elas não têm nome estável.

Os tipos dos parâmetros da função são validados automaticamente. Se os tipos não baterem com os argumentos recebidos, a chamada é ignorada.

## Referência da API

### EnhancedClient

| Método | Descrição |
|--------|-----------|
| `start(peer)` | Inicia o cliente com o peer fornecido |
| `stop()` | Encerra a conexão |
| `poll(timeout_ms?)` | Processa os pacotes recebidos — chame no `_process` |
| `exec(path, args?, channel?)` | Envia uma chamada sem aguardar retorno |
| `invoke(path, args?, channel?)` | Envia uma chamada e aguarda retorno com `await` |
| `get_sender_id()` | Retorna o peer id do remetente do pacote em processamento |
| `register_methods(scope, callables)` | Registra métodos que podem ser chamados remotamente |
| `unregister_methods(scope, callables)` | Remove métodos registrados |

### EnhancedServer

| Método | Descrição |
|--------|-----------|
| `start(peer)` | Inicia o servidor com o peer fornecido |
| `stop()` | Encerra o servidor |
| `poll(timeout_ms?)` | Processa os pacotes recebidos — chame no `_process` |
| `exec(target, path, args?, channel?)` | Envia para um peer, lista ou filtro |
| `invoke(peer_id, path, args?, channel?)` | Envia para um peer e aguarda retorno |
| `get_sender_id()` | Retorna o peer id do remetente do pacote em processamento |
| `register_methods(scope, callables)` | Registra métodos que podem ser chamados remotamente |
| `unregister_methods(scope, callables)` | Remove métodos registrados |

## Licença

MIT