# Copyright (c) 2013 The Mirah project authors. All Rights Reserved.
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

package org.mirah.tool

import java.util.List
import java.util.HashSet
import java.util.logging.Logger
import javax.tools.DiagnosticListener
import mirah.lang.ast.NodeScanner
import mirah.lang.ast.Position
import org.mirah.typer.ErrorType
import org.mirah.typer.FuturePrinter
import org.mirah.typer.Typer
import org.mirah.util.Context
import org.mirah.util.MirahDiagnostic

class ErrorCollector < NodeScanner
  def initialize(context:Context)
    @errors = HashSet.new
    @typer = context[Typer]
    @reporter = context[DiagnosticListener]
  end

  def self.initialize:void
    @@log = Logger.getLogger(ErrorCollector.class.getName)
  end


  def exitDefault(node, arg)
    future = @typer.getInferredType(node)
    type = future.nil? ? nil : future.resolve
    if (type && type.isError)
      if @errors.add(type)
        messages = ErrorType(type).message
        diagnostic = if messages.size >= 1
          items = List(messages[0])
          text = items[0].toString
          position = node.position
          if items.size == 1 && items[1]
            position = Position(items[1])
          end
          MirahDiagnostic.error(position, text)
        else messages.size == 0
          MirahDiagnostic.error(node.position, "Error")
        end
        @reporter.report(diagnostic)
        debug = FuturePrinter.new
        debug.printFuture(future)
        @@log.fine("future:\n#{debug}")
      end
    end
    nil
  end

  def enterBlock(node, arg)
    # There must have already been an error for the method call, so ignore this.
    false
  end
end
