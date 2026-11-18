from __future__ import annotations

from typing import Optional

from ._http import HttpClient
from .resources import Cdr, Events, Groups, Orders, Recordings, Tokens, Users


class Callio:
    """The Callio tenant API client. Keep it on your server: the API key gives full access to your
    organisation's users, orders and recordings.

    >>> callio = Callio(api_key=os.environ["CALLIO_API_KEY"], base_url="https://api.example.sa")
    >>> callio.tokens.for_user("cust-42", display_name="Sara", user_type="customer")["token"]
    """

    def __init__(self, api_key: Optional[str] = None, base_url: Optional[str] = None, *, timeout: float = 30.0,
                 max_retries: int = 2, user_agent: Optional[str] = None, allow_insecure: bool = False) -> None:
        # allow_insecure: development only, permits an http:// base_url (local stack, lab box).
        #: The underlying HTTP client (``request()`` for endpoints the SDK doesn't wrap yet).
        self.http = HttpClient(api_key, base_url, timeout=timeout, max_retries=max_retries, user_agent=user_agent,
                               allow_insecure=allow_insecure)
        self.users = Users(self.http)
        self.tokens = Tokens(self.http, self.users)
        self.orders = Orders(self.http)
        self.recordings = Recordings(self.http)
        self.groups = Groups(self.http)
        self.events = Events(self.http)
        self.cdr = Cdr(self.http)

    def __repr__(self) -> str:
        return f"Callio(base_url={self.http.base_url!r})"
