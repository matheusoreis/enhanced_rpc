# EnhancedRpc

Uma camada RPC para Godot 4 que te dá controle total sobre a serialização dos dados. Em vez de depender do sistema automático do Godot, você escreve e lê os argumentos diretamente em bytes — sem overhead, sem surpresas.

## Como funciona

O sistema tem dois tipos de chamada:

- **`exec`** — envia uma chamada e não espera resposta
- **`invoke`** — envia uma chamada e aguarda um retorno com `await`

Em ambos os casos, você usa um `StreamPeerBuffer` para escrever os dados que quer enviar (`put_float`, `put_u32`, `put_string`...) e o método registrado no outro lado recebe esse mesmo buffer para ler (`get_float`, `get_u32`, `get_string`...).

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
    server.register_methods("game", [
        func mover(ctx: RpcContext, buf: StreamPeerBuffer) -> void:
            var x := buf.get_float()
            var y := buf.get_float()
            # faz algo com x e y...
    ])

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

Passe o caminho `"escopo.metodo"` e uma função que escreve os argumentos no buffer:

```gdscript
client.exec("game.mover", func(buf: StreamPeerBuffer) -> void:
    buf.put_float(x)
    buf.put_float(y)
)
```

Se o método não tiver argumentos, o segundo parâmetro é opcional:

```gdscript
client.exec("game.ping")
```

### invoke — com retorno

Funciona igual ao `exec`, mas retorna um `StreamPeerBuffer` com os dados da resposta:

```gdscript
var buf: StreamPeerBuffer = await client.invoke(
    "game.get_hp",
    func(b: StreamPeerBuffer) -> void:
        b.put_u32(player_id)
)
var hp := buf.get_u16()
```

O método registrado no servidor precisa retornar um `StreamPeerBuffer`:

```gdscript
server.register_methods("game", [
    func get_hp(ctx: RpcContext, buf: StreamPeerBuffer) -> StreamPeerBuffer:
        var player_id := buf.get_u32()
        var out := StreamPeerBuffer.new()
        out.put_u16(jogadores[player_id].hp)
        return out,
])
```

## RpcContext

Todo método registrado no servidor recebe um `RpcContext` como primeiro argumento. Por ele você acessa o `sender_id` — o peer id de quem fez a chamada:

```gdscript
func atacar(ctx: RpcContext, buf: StreamPeerBuffer) -> void:
    print("Peer %d atacou!" % ctx.sender_id)
```

## Broadcast

O servidor pode enviar para mais de um peer ao mesmo tempo. O packet é serializado **uma única vez** independente de quantos peers receberem.

```gdscript
# Peer específico
server.exec(peer_id, "game.spawn", func(buf): buf.put_u32(entidade_id))

# Lista de peers
server.exec([peer_a, peer_b], "game.spawn", func(buf): buf.put_u32(entidade_id))

# Filtrado por uma condição
server.exec(
    func(id: int) -> bool: return time[id] == Time.AZUL,
    "game.spawn",
    func(buf): buf.put_u32(entidade_id)
)
```

## Registrando métodos

```gdscript
server.register_methods("escopo", [func nome_do_metodo(...), ...])
server.unregister_methods("escopo", [func nome_do_metodo(...), ...])
```

O nome do escopo e o nome da função formam juntos o identificador da chamada (`"escopo.metodo"`). Por isso **lambdas não são permitidas** — elas não têm nome estável.

## Referência da API

### EnhancedClient

| Método | Descrição |
|--------|-----------|
| `start(peer)` | Inicia o cliente com o peer fornecido |
| `stop()` | Encerra a conexão |
| `poll(timeout_ms?)` | Processa os packets recebidos — chame no `_process` |
| `exec(path, writer?, channel?)` | Envia uma chamada sem aguardar retorno |
| `invoke(path, writer?, channel?)` | Envia uma chamada e aguarda retorno com `await` |

### EnhancedServer

| Método | Descrição |
|--------|-----------|
| `start(peer)` | Inicia o servidor com o peer fornecido |
| `stop()` | Encerra o servidor |
| `poll(timeout_ms?)` | Processa os packets recebidos — chame no `_process` |
| `exec(target, path, writer?, channel?)` | Envia para um peer, lista ou filtro |
| `invoke(peer_id, path, writer?, channel?)` | Envia para um peer e aguarda retorno |
| `register_methods(scope, callables)` | Registra métodos que podem ser chamados remotamente |
| `unregister_methods(scope, callables)` | Remove métodos registrados |

## Licença

MIT