"""Ponto de entrada do phoned."""

import argparse
import asyncio
import logging
import signal
import sys

from . import config, daemon


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="phoned", description="Daemon do Phone Link")
    parser.add_argument("--state-dir", default=None)
    parser.add_argument("--runtime-dir", default=None)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--name", default=None)
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args(argv)


async def _executa(cfg):
    servico = daemon.Daemon(cfg)
    await servico.start()
    parada = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sinal in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sinal, parada.set)
    try:
        await parada.wait()
    finally:
        await servico.stop()


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    overrides = {}
    if args.port is not None:
        overrides["tcp_port"] = args.port
        overrides["discovery_port"] = args.port
        overrides["announce_targets"] = [("255.255.255.255", args.port)]
    if args.name is not None:
        overrides["name"] = args.name

    try:
        cfg = config.load_config(
            state_dir=args.state_dir, runtime_dir=args.runtime_dir, **overrides
        )
    except OSError as exc:
        print(f"phoned: nao consegui preparar os diretorios: {exc}", file=sys.stderr)
        return 1

    try:
        asyncio.run(_executa(cfg))
    except OSError as exc:
        # Porta ocupada cai aqui. Falhar claro e melhor que trocar de porta,
        # porque porta variavel quebraria a descoberta.
        print(f"phoned: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
