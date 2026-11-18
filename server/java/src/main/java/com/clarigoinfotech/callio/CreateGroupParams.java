package com.clarigoinfotech.callio;

import java.util.ArrayList;
import java.util.List;

/** The body of {@code groups.create}: 2–50 members. */
public final class CreateGroupParams extends Params<CreateGroupParams> {
  public CreateGroupParams(String id, String name, List<String> members) { set("id", id); set("name", name); set("members", new ArrayList<>(members)); }


}
