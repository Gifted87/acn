defmodule ACN.Tools.SpecialistToolsTest do
  use ExUnit.Case
  alias ACN.Tools.SpecialistTools

  test "apply_patch correctly modifies a file" do
    original = """
    defmodule Foo do
      def hello do
        :world
      end
    end
    """

    diff = """
    --- foo.ex
    +++ foo.ex
    @@ -2,3 +2,3 @@
       def hello do
    -    :world
    +    :universe
       end
    """

    worksheet = %{"foo.ex" => original}
    
    {:ok, msg, new_ws} = SpecialistTools.execute(
      %{"name" => "worksheet_patch", "arguments" => %{"filename" => "foo.ex", "diff" => diff}}, 
      worksheet
    )

    assert msg =~ "Patch applied successfully"
    assert new_ws["foo.ex"] =~ ":universe"
    refute new_ws["foo.ex"] =~ ":world"
  end

  test "apply_patch fails on context mismatch (Safety)" do
    original = """
    defmodule Foo do
      def hello do
        :world
      end
    end
    """

    # Diff expects :mars but finds :world
    diff = """
    --- foo.ex
    +++ foo.ex
    @@ -2,3 +2,3 @@
       def hello do
    -    :mars
    +    :universe
       end
    """

    worksheet = %{"foo.ex" => original}
    
    {:ok, msg, _} = SpecialistTools.execute(
      %{"name" => "worksheet_patch", "arguments" => %{"filename" => "foo.ex", "diff" => diff}}, 
      worksheet
    )

    assert msg =~ "Patch Failed"
  end
end
