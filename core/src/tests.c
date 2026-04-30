#include <stdio.h>
#include <assert.h>

void x_to_equal_5() {
  int x = 5;

  assert(x == 5);
  printf("(Pass) x == 5\n");
}

int main() {
  x_to_equal_5();
  return 0;
}
