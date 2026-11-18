package com.clarigoinfotech.callio;

import java.util.List;
import java.util.Map;

/** Group chats: 2–50 members. */
public final class Groups {
  private final CallioHttp http;

  Groups(CallioHttp http) { this.http = http; }

  private Group one(String method, String path, Object body) {
    return new Group(Json.asMap(http.requestObject(method, path, null, body).get("group")));
  }

  public Group create(CreateGroupParams params) { return one("POST", "/api/v1/groups", params); }

  public List<Group> list() {
    return new Users.Wrap(http.requestObject("GET", "/api/v1/groups", null, null)).list("groups", Group::new);
  }

  public Group get(String id) { return one("GET", "/api/v1/groups/" + Seg.of(id), null); }

  /** Rename, add or remove members. Members added later see messages from when they joined. */
  public Group update(String id, UpdateGroupParams params) { return one("PATCH", "/api/v1/groups/" + Seg.of(id), params); }

  /** Deletes the group and its messages. Returns {@code {"ok": true}}. */
  public Map<String, Object> delete(String id) { return http.requestObject("DELETE", "/api/v1/groups/" + Seg.of(id), null, null); }
}
