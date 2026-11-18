package com.clarigoinfotech.callio;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** The body of {@code groups.update}: rename, add or remove members. */
public final class UpdateGroupParams extends Params<UpdateGroupParams> {
  public UpdateGroupParams name(String v) { return set("name", v); }
  public UpdateGroupParams add(List<String> v) { return set("add", new ArrayList<>(v)); }
  public UpdateGroupParams add(String... v) { return add(Arrays.asList(v)); }
  public UpdateGroupParams remove(List<String> v) { return set("remove", new ArrayList<>(v)); }
  public UpdateGroupParams remove(String... v) { return remove(Arrays.asList(v)); }
}
