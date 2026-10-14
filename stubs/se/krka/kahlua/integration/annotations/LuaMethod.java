package se.krka.kahlua.integration.annotations;

import java.lang.annotation.*;

/** COMPILE-TIME STUB ONLY. The real class ships with Project Zomboid. Never packaged into the jar. */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface LuaMethod {
    String name() default "";
    boolean global() default false;
}
