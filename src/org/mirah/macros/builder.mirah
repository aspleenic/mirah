# Copyright (c) 2012 The Mirah project authors. All Rights Reserved.
# All contributing project authors may be found in the NOTICE file.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package org.mirah.macros

import java.io.InputStream
import java.util.Arrays
import java.util.HashMap
import java.util.LinkedList
import java.util.List
import mirah.impl.MirahParser
import mirah.lang.ast.Arguments
import mirah.lang.ast.Array
import mirah.lang.ast.Call
import mirah.lang.ast.Cast
import mirah.lang.ast.FieldAccess
import mirah.lang.ast.Fixnum
import mirah.lang.ast.MacroDefinition
import mirah.lang.ast.Node
import mirah.lang.ast.NodeList
import mirah.lang.ast.NodeScanner
import mirah.lang.ast.Package
import mirah.lang.ast.RequiredArgument
import mirah.lang.ast.Script
import mirah.lang.ast.SimpleString
import mirah.lang.ast.StreamCodeSource
import mirah.lang.ast.StringCodeSource
import mirah.lang.ast.StringConcat
import mirah.lang.ast.TypeName
import org.mirah.typer.Scope
import org.mirah.typer.Typer

class ValueSetter < NodeScanner
  def initialize(objects:List)
    @index = 0
    @objects = objects
  end
  
  def enterUnquote(node, arg)
    node.object = @objects.get(@index)
    @index += 1
    true
  end
end

class ValueGetter < NodeScanner
  def initialize
    @values = NodeList.new
  end
  
  def enterUnquote(node, arg)
    @values.add(node.value)
    true
  end
  
  def values
    array = Array.new
    array.values = @values
    array
  end
end

class MacroBuilder; implements Compiler
  def initialize(typer:Typer, backend:JvmBackend)
    @typer = typer
    @types = typer.type_system
    @scopes = typer.scoper
    @backend = backend
    @extension_counters = HashMap.new
  end
  
  def buildExtension(macroDef:MacroDefinition)
    ast = constructAst(macroDef)
    @typer.infer(ast)
    klass = @backend.compileAndLoadExtension(ast)
    registerLoadedMacro(macroDef, klass)
  end
  
  def serializeAst(node:Node, call:Call):Object
    result = Object[5]
    result[0] = node.position.source.name
    result[1] = Fixnum.new(node.position.startLine)
    result[2] = Fixnum.new(node.position.startColumn)
    result[3] = splitString(node.position.source.substring(node.position.startChar,
                                                           node.position.endChar))
    collector = ValueGetter.new
    collector.scan(node)
    result[4] = collector.values
    Arrays.asList(result)
  end
  
  def deserializeScript(filename:String, code:InputStream, values:List):Script
    parser = MirahParser.new
    script = Script(parser.parse(StreamCodeSource.new(filename, code)))
    ValueSetter.new(values).scan(script)
    script
  end
  
  def deserializeAst(filename:String, startLine:int, startCol:int, code:String, values:List, scope:Scope):Node
    parser = MirahParser.new
    script = Script(parser.parse(StringCodeSource.new(filename, code, startLine, startCol)))
    # TODO(ribrdb) scope
    ValueSetter.new(values).scan(script)
    if script.body_size == 1
      script.body(0)
    else
      script.body
    end
  end

  # If the string is too long split it into multiple string constants.
  def splitString(string:String):Object
    if string.length < 65535
      Object(string)
    else
      result = StringConcat.new
      while string.length >= 65535
        result.add(SimpleString.new(string.substring(0, 65535)))
        string = string.substring(65535)
      end
      result.add(SimpleString.new(string))
      result
    end
  end
  
  def constructAst(macroDef:MacroDefinition):Script
    template = MacroBuilder.class.getResourceAsStream("template.mirah.tpl")
    name = extensionName(macroDef)
    addMissingTypes(macroDef)
    casts = makeCasts(macroDef.arguments)
    script = deserializeScript("template.mirah.tpl", template,
                               [name, macroDef.arguments.clone, macroDef.body, casts])
    scope = @scopes.getScope(macroDef)
    if scope.package
      script.body.insert(0, Package.new(SimpleString.new(scope.package), nil))
    end
    script
  end
  
  def extensionName(macroDef:MacroDefinition)
    enclosing_type = @scopes.getScope(macroDef).selfType.resolve
    counter = Integer(@extension_counters.get(enclosing_type))
    if counter.nil?
      id = 1
    else
      id = counter.intValue + 1
    end
    @extension_counters.put(enclosing_type, Integer.new(id))
    "#{enclosing_type.name}$Extension#{id}"
  end
  
  # Adds types to the arguments with none specified.
  # Uses Block for a block argument and Node for any other argument.
  def addMissingTypes(macroDef:MacroDefinition):void
    # TODO optional, rest args
    macroDef.arguments.required.each do |_arg|
      arg = RequiredArgument(_arg)
      if arg.type.nil?
        arg.type = SimpleString.new('mirah.lang.ast.Node')
      end
    end
    block = macroDef.arguments.block
    block.type = SimpleString.new('mirah.lang.ast.Block') if (block && block.type.nil?)
  end

  def makeCasts(args:Arguments):List
    casts = LinkedList.new
    i = 0
    args.required.each do |_arg|
      arg = RequiredArgument(_arg)
      casts.add(Cast.new(TypeName(arg.type.clone), fetchMacroArg(i)))
      i += 1
    end
    casts
  end
  
  # Returns a node to fetch the i'th macro argument during expansion.
  def fetchMacroArg(i:int):Node
    Call.new(FieldAccess.new(SimpleString.new('call')), SimpleString.new('get'), [Fixnum.new(i)], nil)
  end
  
  def registerLoadedMacro(macroDef:MacroDefinition, klass:Class):void
    extended_class = @scopes.getScope(macroDef).selfType.resolve
    arg_types = @typer.inferAll(macroDef.arguments)
    @types.addMacro(extended_class, macroDef.name.identifier, arg_types)
  end
end