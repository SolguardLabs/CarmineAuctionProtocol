import pytest
from eth_tester import PyEVMBackend
from web3 import EthereumTesterProvider, Web3


@pytest.fixture()
def w3():
    provider = EthereumTesterProvider(PyEVMBackend())
    web3 = Web3(provider)
    web3.eth.default_account = web3.eth.accounts[0]
    return web3
